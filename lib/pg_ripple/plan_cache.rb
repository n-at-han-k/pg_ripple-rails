# frozen_string_literal: true

module PgRipple
  # pg_ripple's per-backend SPARQL plan cache, and the one thing a host
  # application has to know about it: **a rolled-back transaction leaves it
  # holding plans that can never match another row again.**
  #
  # The mechanism, measured in `docs/probe-cache-invalidation.md`:
  #
  # * pg_ripple compiles a SPARQL query to SQL with the dictionary ids of its
  #   constants **embedded as integer literals**, and caches that SQL per
  #   backend, keyed on the query text.
  # * `ROLLBACK` removes the dictionary rows those ids named. pg_ripple 0.128.0
  #   clears its dictionary caches on abort but never resets the plan cache.
  # * The next execution of the same query text is a cache hit, filters on ids
  #   that no longer exist, and returns **zero rows** — silently, for the
  #   lifetime of that backend.
  #
  # This is not a test-only hazard. The dangerous query is one with a *stable*
  # constant — `Person.graph.where(role: "engineer")` mints `"engineer"` once,
  # ever, and `alice.colleagues` embeds Alice's IRI in every traversal. If the
  # transaction that first minted the term aborts, that pooled connection
  # answers that query with nothing for the rest of its life while the other
  # connections in the pool answer correctly.
  #
  # The gem's response, in one sentence: **every rollback marks the connection,
  # and the next pg_ripple statement on it runs `pg_ripple.plan_cache_reset()`
  # first.** One extra round trip per abort, on a connection that has actually
  # run a pg_ripple statement, and nothing at all on a connection that has not.
  #
  # Why lazily, on the next statement, rather than in the rollback itself:
  # `#exec_rollback_db_transaction` runs while the transaction manager still
  # has the aborted transaction on its stack, and issuing a query there can
  # materialise a fresh `BEGIN` that nobody asked for. Marking is a flag
  # assignment and cannot fail; the reset then happens in the ordinary place
  # where this gem talks to the database.
  #
  # @see PgRipple::PlanCache::Invalidation the rollback hook
  # @see PgRipple.reset_plan_cache! the manual escape hatch
  module PlanCache
    # The extension function that clears the cache. `DISCARD ALL`,
    # `pg_ripple.flush_encode_cache()` and `pg_ripple.invalidate_catalog_cache()`
    # were all measured and none of them clears it; `pg_ripple.plan_cache_size
    # = 0` is documented as a kill switch and is a no-op.
    RESET_SQL = "SELECT pg_ripple.plan_cache_reset()"

    # Ivar on the connection object rather than a keyed registry: the state
    # belongs to one backend, and it has to die exactly when the connection
    # does. A pool that reconnects hands back a new adapter object with no
    # ivars, which is correct — a new backend has an empty plan cache.
    TOUCHED = :@pg_ripple_plan_cache_touched
    POISONED = :@pg_ripple_plan_cache_poisoned

    class << self
      # Records that a pg_ripple statement has run on this connection, so a
      # later rollback knows there is a plan cache worth resetting.
      #
      # Only called from the gem's own statement paths, which is what makes
      # {.reset!} safe to issue without first asking whether the extension is
      # installed: an untouched connection is never poisoned, and a touched one
      # has already executed a `pg_ripple.*` function successfully.
      #
      # @param connection [ActiveRecord::ConnectionAdapters::AbstractAdapter]
      # @return [void]
      def touched!(connection)
        raw(connection).instance_variable_set(TOUCHED, true)
      end

      # @return [Boolean]
      def touched?(connection)
        !!raw(connection).instance_variable_get(TOUCHED)
      end

      # Marks a connection whose transaction aborted.
      #
      # A no-op on a connection this gem has never run a statement on, and a
      # no-op when {PgRipple::Configuration#reset_plan_cache_on_rollback} is
      # off. Never raises and never queries: it runs inside the rollback.
      #
      # @return [void]
      def poison!(connection)
        return unless PgRipple.configuration.reset_plan_cache_on_rollback
        return unless touched?(connection)

        raw(connection).instance_variable_set(POISONED, true)
      end

      # @return [Boolean]
      def poisoned?(connection)
        !!raw(connection).instance_variable_get(POISONED)
      end

      # Runs a block that executes pg_ripple SQL on this connection.
      #
      # The whole protocol in one place: reset the cache if a rollback poisoned
      # it, mark the connection so a *later* rollback knows there is a cache
      # worth resetting, and treat a statement that raised as poisoning too —
      # a failing statement has already minted dictionary ids for the constants
      # it parsed, and an abort outside an explicit transaction never reaches a
      # `ROLLBACK` this gem could hook.
      #
      # Marked before the statement rather than after it, for the same reason.
      #
      # Two callers, and they are not alike:
      # {PgRipple::ConnectionLeasing#with_ripple_statement}, which owns the
      # connection it is given, and {PgRipple::Preloading::RelationMethods},
      # which runs `pg_ripple.sparql()` through ActiveRecord's own query path
      # in a `JOIN LATERAL` and so never passes through the leasing seam at
      # all. That second path is `Model.graph`, every `graph_has_many` reader
      # and every property-path traversal — "the most exposed queries in the
      # gem" (`docs/probe-cache-invalidation.md` §3) — and until this method
      # existed it neither marked nor recovered.
      #
      # @param connection [ActiveRecord::ConnectionAdapters::AbstractAdapter]
      # @return [Object] the block's value
      def around_statement(connection)
        recover!(connection)
        touched!(connection)

        begin
          yield
        rescue ActiveRecord::StatementInvalid
          poison!(connection)
          raise
        end
      end

      # Clears the cache if a rollback has poisoned it. Called at the gem's
      # connection seam, before every statement.
      #
      # The mark survives a failed reset. The one way this fails in practice is
      # a connection whose transaction is still in the aborted state — the
      # rollback that ends it will mark the connection again, but leaving the
      # mark set means the reset is not *skipped* if it does not.
      #
      # @return [Boolean] whether a reset was issued
      def recover!(connection)
        return false unless poisoned?(connection)

        reset!(connection).tap do |reset|
          raw(connection).instance_variable_set(POISONED, false) if reset
        end
      end

      # Clears the plan cache on this connection, whether or not anything
      # poisoned it.
      #
      # Loud on failure rather than silent: the only way this fails is a
      # connection where `pg_ripple.plan_cache_reset()` does not exist, and a
      # host application that has wired this gem to such a database wants to
      # hear about it once.
      #
      # @return [Boolean] whether the reset ran
      def reset!(connection)
        # `exec_update`, not `exec_query`: `plan_cache_reset()` returns `void`,
        # and building a result set over a void column makes the pg gem warn
        # "unknown OID 2278" on every call. Same reason as
        # `PgRipple::Adapters::Postgres#execute_with_binds`.
        raw(connection).exec_update(RESET_SQL, "pg_ripple")
        true
      rescue ActiveRecord::StatementInvalid => error
        complain(error)
        false
      end

      private

      # The adapter itself, never {PgRipple::Adapters::Postgres::Connection}'s
      # delegator — a new delegator is built per call, so an ivar set on one
      # would be thrown away with it.
      def raw(connection)
        connection.respond_to?(:__getobj__) ? connection.__getobj__ : connection
      end

      def complain(error)
        return if @complained

        @complained = true

        message = "[pg_ripple] could not reset the SPARQL plan cache " \
          "(#{error.class}: #{error.message.lines.first&.strip}). Queries on this " \
          "connection may return no rows after a rolled-back transaction. See " \
          "PgRipple::PlanCache."

        ActiveRecord::Base.logger&.warn(message)
        warn(message)
      end
    end

    # Prepended onto the PostgreSQL adapter by {PgRipple.load}.
    #
    # Both spellings of "the transaction went away" are covered: a top-level
    # `ROLLBACK`, and `ROLLBACK TO SAVEPOINT`, which is what
    # `transaction(requires_new: true)` and `ActiveRecord::Rollback` produce
    # inside a transactional test suite.
    #
    # `ensure`, so a rollback that itself raises still marks the connection.
    #
    # And one more thing, which is not about rollback at all: it marks the
    # connection for the `JOIN LATERAL` over `pg_ripple.sparql()`. That query
    # is built by this gem but *run* by ActiveRecord, so it never passes
    # through {PgRipple::ConnectionLeasing} — see
    # {PgRipple::PlanCache.around_statement} for what went wrong without this.
    module Invalidation
      # Every statement the adapter runs, with the traversals singled out.
      #
      # `#internal_exec_query` and not `#exec_query`, because the interesting
      # callers are not the gem's: `Relation#load`, `#count`, `#pluck` and
      # `#exists?` all reach the server through `select_all` → `select` →
      # `internal_exec_query`, and only the first of them goes anywhere near
      # `#exec_queries`. Hooking the one method covers all four.
      #
      # The test is {PgRipple::Relation.lateral?} — an `include?` of this gem's
      # own join-alias prefix — so an ordinary application query pays one
      # substring search against a string it just built, and the reset issued
      # by {PgRipple::PlanCache.recover!} cannot match itself and recurse.
      def internal_exec_query(sql, ...)
        return super unless PgRipple::Relation.lateral?(sql)

        PgRipple::PlanCache.around_statement(self) { super }
      end

      def exec_rollback_db_transaction(...)
        super
      ensure
        PgRipple::PlanCache.poison!(self)
      end

      def exec_restart_db_transaction(...)
        super
      ensure
        PgRipple::PlanCache.poison!(self)
      end

      def exec_rollback_to_savepoint(...)
        super
      ensure
        PgRipple::PlanCache.poison!(self)
      end
    end
  end
end

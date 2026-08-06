# frozen_string_literal: true

require "pg_ripple/plan_cache"

module PgRipple
  # The one place this gem gets an ActiveRecord connection.
  #
  # `#with_connection`, not `#connection` and not `#lease_connection`.
  #
  # `ActiveRecord::Base.connection` is the deprecated permanent-checkout API.
  # Under `ActiveRecord.permanent_connection_checkout = :disallowed` — the
  # setting Rails is moving towards — it raises `ActiveRecordError: Called
  # deprecated 'ActiveRecord::Base.connection' method`, so with `#connection`
  # every graph read, every graph write and every migration in this gem was
  # unrunnable. Under `:deprecated` it pins a pool connection to the thread for
  # the process lifetime, which is its own bug in a job or a thread pool.
  #
  # `#lease_connection` avoids the raise but keeps the pin: the connection
  # stays checked out until the request or job ends, which is exactly the
  # behaviour Rails is deprecating. `#with_connection` checks the connection
  # back in when the block returns — unless something else already leased it,
  # in which case it yields *that* connection and leaves the lease alone.
  #
  # That last clause is what preserves the property the lease was chosen for:
  # pg_ripple is only transactional with the application's own writes when it
  # runs on the connection the application is already using, and inside an
  # `ActiveRecord::Base.transaction` — or the application's own
  # `with_connection` block — there *is* such a connection and it is the one
  # yielded here. Outside a transaction each statement is its own transaction
  # anyway, so a different pool member is not a correctness question.
  #
  # The lifetime rule that comes with the block form: **nothing that outlives
  # the block may hold the connection.** Every caller below finishes its work
  # inside — `exec_query(...).rows` and `QueryExecutor.call` both materialise
  # before returning — and nothing is handed back that would query later.
  #
  # Rails 7.1 has no `#with_connection`; there `#connection` is neither
  # deprecated nor disallowed, and the fallback yields it.
  #
  # @see docs/spec-corrections.md §15
  module ConnectionLeasing
    private

    # @yieldparam connection [ActiveRecord::ConnectionAdapters::AbstractAdapter]
    def with_ripple_connection
      if connectable.respond_to?(:with_connection)
        connectable.with_connection do |connection|
          PgRipple::PlanCache.recover!(connection)
          yield connection
        end
      else
        connection = connectable.connection
        PgRipple::PlanCache.recover!(connection)
        yield connection
      end
    end

    # As {#with_ripple_connection}, for a statement that runs `pg_ripple.*` SQL.
    #
    # The marking, the recovery and the treatment of a failed statement all
    # live in {PgRipple::PlanCache.around_statement}, because this is not the
    # only path that runs pg_ripple SQL: the `JOIN LATERAL` over
    # `pg_ripple.sparql()` goes through ActiveRecord's own query path and never
    # reaches this seam.
    def with_ripple_statement
      with_ripple_connection do |connection|
        PgRipple::PlanCache.around_statement(connection) { yield connection }
      end
    end
  end
end

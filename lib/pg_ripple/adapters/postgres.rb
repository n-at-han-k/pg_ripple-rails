# frozen_string_literal: true

require "pg_ripple/adapters/postgres/connection"
require "pg_ripple/adapters/postgres/prefixes"
require "pg_ripple/adapters/postgres/shapes"
require "pg_ripple/adapters/postgres/rule_sets"
require "pg_ripple/adapters/postgres/sparql_views"
require "pg_ripple/adapters/postgres/endpoints"

module PgRipple
  # Base class for the errors this gem raises itself, as opposed to the
  # PG::Error and ActiveRecord::StatementInvalid that come back from the server.
  #
  # Defined here because the adapter is the only thing that raises so far;
  # phase 4 may lift these into their own file when the statements grow their
  # own argument validation.
  class Error < StandardError
  end

  # Raised when an operation needs an extension the database does not have.
  #
  # Only ever raised for pg_trickle. A missing pg_ripple is a no-op, not an
  # error — see {PgRipple::Adapters::Postgres#pg_ripple_enabled?}.
  class MissingExtensionError < Error
  end

  # Raised when `create_sparql_view` fails on a view that did not previously
  # exist, which in pg_ripple 0.128.0 against pg_trickle 0.68.0 is every first
  # creation. See {PgRipple::Adapters::Postgres#create_sparql_view}.
  class SparqlViewCreationError < Error
  end

  # Database adapters.
  #
  # Ships with a Postgres adapter only — pg_ripple is a Postgres extension, so
  # there is no other engine to support — but the interface is the one F(x)
  # defines, so an alternative could be substituted the same way.
  module Adapters
    # The Postgres adapter. The only place in the gem that executes SQL.
    #
    # Two rules hold for every method below.
    #
    # **Documents are bound, never interpolated.** A Turtle shape file, a
    # Datalog program and a SPARQL query are all full of quotes, and a SPARQL
    # query is full of `$` besides. pg_cron had to assemble `cron.schedule()`
    # as text because its payload IS SQL; pg_ripple's payloads are arguments to
    # a function call, so they go over the wire as parameters
    # (`SELECT pg_ripple.load_shacl($1::text)`) and no quoting question arises.
    # The casts are explicit so an untyped parameter never has to be resolved
    # against an overload.
    #
    # **Writes no-op without the extension.** A migration that loads a shape
    # still runs against a database with no pg_ripple — a test database, or an
    # environment where the store is not wanted — instead of every such
    # migration needing its own guard. Readers return `[]` for the same reason:
    # `_pg_ripple.*` does not exist then, and `db:schema:dump` must not fail on
    # a database that simply has no triple store.
    #
    # @param [#connection] connectable An object that returns the connection to
    #   use. Defaults to `ActiveRecord::Base`.
    #
    # @example
    #  PgRipple.configure do |config|
    #    config.adapter = PgRipple::Adapters::Postgres.new
    #  end
    class Postgres
      # The schedule `create_sparql_view` itself defaults to. Repeated here
      # rather than left to the server default because the dumper has to write
      # a value out, and the two must agree.
      DEFAULT_VIEW_SCHEDULE = "1s"

      def initialize(connectable = ActiveRecord::Base)
        @connectable = connectable
      end

      # Whether pg_ripple is installed in this database.
      #
      # Checked by every statement and every reader below.
      def pg_ripple_enabled?
        connection.pg_ripple_enabled?
      end

      # Whether pg_trickle is installed in this database.
      #
      # A second, narrower guard, needed only by SPARQL views. pg_trickle is a
      # soft dependency: the published image ships it, but
      # `CREATE EXTENSION pg_ripple` does not install it and `CASCADE` does not
      # pull it in, so `pg_ripple_enabled?` alone does not imply a view can be
      # created.
      def pg_trickle_enabled?
        connection.pg_trickle_enabled?
      end

      # The installed pg_ripple version, e.g. "0.128.0", or nil when absent.
      #
      # Not enforced in v1: it is surfaced by `rake pg_ripple:status` and
      # written into a comment at the head of the dumped section, so a schema
      # diff shows when the extension moved under the application.
      #
      # @return [String, nil]
      def pg_ripple_version
        return nil unless pg_ripple_enabled?

        connection.pg_ripple_version
      end

      # Every registered namespace prefix, minus the ones pg_ripple seeds.
      #
      # @return [Array<PgRipple::Prefix>]
      def prefixes
        return [] unless pg_ripple_enabled?

        PgRipple::Adapters::Postgres::Prefixes.all(connection)
      end

      # Every loaded SHACL shape.
      #
      # Described rather than reproduced by the dumper: the catalog keeps the
      # parsed shape, not its Turtle.
      #
      # @return [Array<PgRipple::Shape>]
      def shapes
        return [] unless pg_ripple_enabled?

        PgRipple::Adapters::Postgres::Shapes.all(connection)
      end

      # Every Datalog rule set, with its rules re-joined in load order.
      #
      # @return [Array<PgRipple::RuleSet>]
      def rule_sets
        return [] unless pg_ripple_enabled?

        PgRipple::Adapters::Postgres::RuleSets.all(connection)
      end

      # Every SPARQL view.
      #
      # Guarded on pg_ripple only. `_pg_ripple.sparql_views` is pg_ripple's own
      # catalog and is readable whether or not pg_trickle is installed — a
      # database that lost pg_trickle still has views to dump.
      #
      # @return [Array<PgRipple::SparqlView>]
      def sparql_views
        return [] unless pg_ripple_enabled?

        PgRipple::Adapters::Postgres::SparqlViews.all(connection)
      end

      # Every registered federation endpoint.
      #
      # @return [Array<PgRipple::Endpoint>]
      def endpoints
        return [] unless pg_ripple_enabled?

        PgRipple::Adapters::Postgres::Endpoints.all(connection)
      end

      # Registers a namespace prefix.
      #
      # `register_prefix` upserts on the prefix, so this serves create and
      # update alike and there is no separate update method.
      #
      # @param prefix [String, Symbol] The prefix, without the colon.
      # @param expansion [String] The IRI the prefix abbreviates.
      # @return [void]
      def create_prefix(prefix, expansion)
        return unless pg_ripple_enabled?

        execute_with_binds(
          "SELECT pg_ripple.register_prefix($1::text, $2::text)",
          prefix, expansion
        )
      end

      # Removes a namespace prefix.
      #
      # The one write in this adapter that is not a function call: pg_ripple
      # exposes `register_prefix` and `prefixes()` and nothing that deletes.
      # `_pg_ripple.prefixes` is a plain two-column table with `prefix` as its
      # primary key and no dependent state anywhere — a prefix is an
      # abbreviation used when parsing and printing, not something the store
      # holds references to — so deleting the row is the whole operation. This
      # is a deliberate exception to "never touch another extension's catalog";
      # without it `drop_ripple_prefix` could not exist and a migration that
      # registered a prefix would be irreversible.
      #
      # @param prefix [String, Symbol] The prefix to remove.
      # @return [void]
      def drop_prefix(prefix)
        return unless pg_ripple_enabled?

        execute_with_binds(
          "DELETE FROM _pg_ripple.prefixes WHERE prefix = $1::text",
          prefix
        )
      end

      # Loads a SHACL document.
      #
      # @param turtle [String] The Turtle source of one or more node shapes.
      # @return [Integer, nil] Number of shapes loaded, nil when pg_ripple is absent.
      def create_shapes(turtle)
        return unless pg_ripple_enabled?

        value_with_binds("SELECT pg_ripple.load_shacl($1::text)", turtle)
      end

      # Reloads a SHACL document and drops the shapes it no longer declares.
      #
      # NOT drop-then-load. `_pg_ripple.shacl_shapes` is keyed on `shape_iri`
      # and `load_shacl` upserts the whole JSON document for each IRI it finds,
      # so a shape present in both versions is correctly replaced — properties
      # are not merged — by the load alone.
      #
      # The gap is the shape the OLD document declared and the new one does
      # not: it stays in the catalog, stays active, and keeps validating. The
      # catalog cannot find it, because a multi-shape document is shredded into
      # independent rows with no source column and no grouping key. So the
      # caller works the orphans out from the previous version's file on disk
      # and passes them here; this only executes them, in the same transaction
      # as the load, so a wrong guess rolls back with the migration.
      #
      # @param turtle [String] The Turtle source of the new version.
      # @param orphaned_shape_iris [Array<String>] Shape IRIs the previous
      #   version declared and this one does not.
      # @return [void]
      def update_shapes(turtle, orphaned_shape_iris = [])
        return unless pg_ripple_enabled?

        connection.transaction do
          create_shapes(turtle)
          orphaned_shape_iris.each { |shape_iri| drop_shape(shape_iri) }
        end
      end

      # Drops a single SHACL shape.
      #
      # Shapes are dropped one IRI at a time because that is the only handle
      # `drop_shape` offers — there is no "drop everything this file loaded".
      #
      # @param shape_iri [String] The IRI of the shape to drop.
      # @return [void]
      def drop_shape(shape_iri)
        return unless pg_ripple_enabled?

        execute_with_binds("SELECT pg_ripple.drop_shape($1::text)", shape_iri)
      end

      # Loads a Datalog rule set.
      #
      # Note the argument order at the call site: `load_rules(rules, rule_set)`
      # takes the PROGRAM first and the name second, the reverse of what
      # `sql-functions.md` documents. Bound the other way round it does not
      # fail — it loads the rule set's name as a Datalog program.
      #
      # @param name [String, Symbol] The name of the rule set.
      # @param program [String] The Datalog rules.
      # @return [Integer, nil] Number of rules loaded, nil when pg_ripple is absent.
      def create_rules(name, program)
        return unless pg_ripple_enabled?

        value_with_binds(
          "SELECT pg_ripple.load_rules($1::text, $2::text)",
          program, name
        )
      end

      # Replaces a Datalog rule set.
      #
      # A single `load_rules` call, not `drop_rules` then `load_rules`.
      # `load_rules` already replaces a set of the same name — delete then
      # insert, proved by the identity sequence advancing — and dropping first
      # is not merely redundant but worse: `drop_rules` additionally retracts
      # the materialised inferences that a straight reload preserves.
      #
      # @param name [String, Symbol] The name of the rule set.
      # @param program [String] The Datalog rules.
      # @return [Integer, nil] Number of rules loaded, nil when pg_ripple is absent.
      def update_rules(name, program)
        create_rules(name, program)
      end

      # Deactivates a Datalog rule set without dropping it.
      #
      # `disable_rule_set` clears `_pg_ripple.rule_sets.active`, so the set
      # stops taking part in inference while its rules stay in the catalog and
      # the triples it already inferred stay in the store. Present because the
      # dumper has to be able to reproduce an inactive set: `load_rules` always
      # creates an active one, so a `create_ripple_rules` alone would restore a
      # rule set that infers where the source database's did not.
      #
      # @param name [String, Symbol] The name of the rule set.
      # @return [void]
      def disable_rules(name)
        return unless pg_ripple_enabled?

        execute_with_binds("SELECT pg_ripple.disable_rule_set($1::text)", name)
      end

      # Reactivates a Datalog rule set.
      #
      # The inverse of {#disable_rules}, and the only reason it exists: a
      # migration that disables a rule set has to be able to roll back.
      #
      # @param name [String, Symbol] The name of the rule set.
      # @return [void]
      def enable_rules(name)
        return unless pg_ripple_enabled?

        execute_with_binds("SELECT pg_ripple.enable_rule_set($1::text)", name)
      end

      # Drops a Datalog rule set, retracting what it inferred.
      #
      # @param name [String, Symbol] The name of the rule set to drop.
      # @return [void]
      def drop_rules(name)
        return unless pg_ripple_enabled?

        execute_with_binds("SELECT pg_ripple.drop_rules($1::text)", name)
      end

      # Creates a SPARQL view.
      #
      # A view is a scheduled, incrementally-maintained pg_trickle stream
      # table, so `schedule` and `decode` are part of the definition and are
      # always sent explicitly rather than left to the server's defaults — the
      # dumper has to write a value out and the two must agree. `immediate` is
      # not stored anywhere, so it is an argument here and a default in the
      # dump.
      #
      # **Known failure, upstream.** In pg_ripple 0.128.0 against pg_trickle
      # 0.68.0 this fails for any view that does not already exist:
      # `create_sparql_view` calls `pgtrickle.drop_stream_table` unconditionally
      # for idempotence (upstream issue #83) and pg_trickle raises a hard ERROR
      # when the table is absent. Rather than pre-creating a placeholder stream
      # table — which would hard-code another extension's internals into this
      # gem, and would leave that table behind if the create then failed for a
      # real reason — a first creation that fails is re-raised as a
      # {PgRipple::SparqlViewCreationError} naming the bug, with the server's
      # own message attached. When the fix lands upstream the create simply
      # succeeds and nothing here changes.
      #
      # @param name [String, Symbol] The name of the view.
      # @param sparql [String] The SPARQL query.
      # @param schedule [String] Refresh interval, e.g. "1s", "5 minutes".
      # @param decode [Boolean] Decode term ids to their lexical values.
      # @param immediate [Boolean] Populate the stream table on creation.
      # @return [void]
      def create_sparql_view(name, sparql, schedule: DEFAULT_VIEW_SCHEDULE, decode: false, immediate: false)
        return unless pg_ripple_enabled?

        require_pg_trickle!(name)
        existed = sparql_view_exists?(name)

        execute_with_binds(
          <<~SQL,
            SELECT pg_ripple.create_sparql_view(
                $1::text, $2::text, $3::text, $4::boolean, $5::boolean
            )
          SQL
          name, sparql, schedule, decode, immediate
        )
      rescue ActiveRecord::StatementInvalid => error
        raise error if existed

        raise SparqlViewCreationError, <<~MESSAGE.strip
          Could not create SPARQL view #{name}.

          pg_ripple's create_sparql_view calls pgtrickle.drop_stream_table
          unconditionally, and pg_trickle raises when the stream table does not
          yet exist, so in pg_ripple 0.128.0 with pg_trickle 0.68.0 the FIRST
          creation of any view fails. Check whether the version pair in this
          database still carries that bug before reading the server error below
          as your own.

          #{error.message}
        MESSAGE
      end

      # Replaces a SPARQL view.
      #
      # A single `create_sparql_view` call. The unconditional
      # `drop_stream_table` that breaks a first creation is exactly what makes
      # a re-creation work, so an update needs no drop of its own — and a drop
      # first would leave the application reading nothing until the next
      # refresh completed.
      #
      # @param (see #create_sparql_view)
      # @return [void]
      def update_sparql_view(name, sparql, schedule: DEFAULT_VIEW_SCHEDULE, decode: false, immediate: false)
        create_sparql_view(name, sparql, schedule: schedule, decode: decode, immediate: immediate)
      end

      # Drops a SPARQL view and its stream table.
      #
      # @param name [String, Symbol] The name of the view to drop.
      # @return [void]
      def drop_sparql_view(name)
        return unless pg_ripple_enabled?

        require_pg_trickle!(name)

        execute_with_binds("SELECT pg_ripple.drop_sparql_view($1::text)", name)
      end

      # Registers a federation endpoint.
      #
      # Keyed on the URL — there is no name in the endpoint API — and
      # `register_endpoint` upserts on it, so this serves create and update
      # alike. Note that the upsert also forces `enabled` back to true.
      #
      # Credentials are not set here. `set_federation_credential` stores
      # pgcrypto-encrypted tokens, and a secret does not belong in a migration.
      #
      # @param url [String] The endpoint's SPARQL URL.
      # @param local_view_name [String, nil] A local view to answer from instead.
      # @param complexity [String, nil] "fast", "normal" or "slow".
      # @param graph_iri [String, nil] The graph this endpoint stands for.
      # @return [void]
      def create_endpoint(url, local_view_name: nil, complexity: nil, graph_iri: nil)
        return unless pg_ripple_enabled?

        execute_with_binds(
          <<~SQL,
            SELECT pg_ripple.register_endpoint(
                $1::text, $2::text, $3::text, $4::text
            )
          SQL
          url, local_view_name, complexity, graph_iri
        )
      end

      # Removes a federation endpoint.
      #
      # @param url [String] The URL of the endpoint to remove.
      # @return [void]
      def drop_endpoint(url)
        return unless pg_ripple_enabled?

        execute_with_binds("SELECT pg_ripple.remove_endpoint($1::text)", url)
      end

      private

      attr_reader :connectable

      def connection
        PgRipple::Adapters::Postgres::Connection.new(connectable.connection)
      end

      # Runs a statement with its arguments bound as parameters, discarding the
      # result.
      #
      # Every value is sent as text and cast in the SQL. That keeps one code
      # path for strings, booleans and NULLs, and means a document never meets
      # a quoting rule on its way to the server.
      #
      # `exec_update` rather than `exec_query` because three of these functions
      # — register_prefix, register_endpoint, remove_endpoint — return `void`,
      # and building a result set over a void column makes the pg gem warn
      # "unknown OID 2278: failed to recognize type of 'register_prefix'" on
      # every migration. `exec_update` reads cmd_tuples and never consults the
      # type map. There is nothing to cast void to that would silence it, so
      # this is the fix rather than a preference.
      def execute_with_binds(sql, *values)
        connection.exec_update(sql, "pg_ripple", binds_for(values))
      end

      # As {#execute_with_binds}, for the functions whose return value the
      # caller wants — `load_shacl` and `load_rules` both return a count.
      def value_with_binds(sql, *values)
        connection.exec_query(sql, "pg_ripple", binds_for(values)).rows.dig(0, 0)
      end

      def binds_for(values)
        values.map.with_index(1) do |value, position|
          ActiveRecord::Relation::QueryAttribute.new(
            "$#{position}",
            value.nil? ? nil : value.to_s,
            ActiveRecord::Type::Value.new
          )
        end
      end

      def sparql_view_exists?(name)
        value_with_binds(
          "SELECT 1 FROM _pg_ripple.sparql_views WHERE name = $1::text",
          name
        ).present?
      end

      # A missing pg_ripple is a no-op; a missing pg_trickle is not.
      #
      # The difference is what the caller can conclude. A database without
      # pg_ripple has no triple store and wants none, so skipping the statement
      # is right. A database WITH pg_ripple but without pg_trickle wants the
      # store and has a half-installed one: silently skipping the view would
      # leave the application querying a relation that never appears, and the
      # fix is a single CREATE EXTENSION.
      def require_pg_trickle!(name)
        return if pg_trickle_enabled?

        raise MissingExtensionError, <<~MESSAGE.strip
          SPARQL view #{name} needs pg_trickle, which is not installed in this database.

          A SPARQL view is a scheduled pg_trickle stream table. pg_ripple does
          not install pg_trickle — CREATE EXTENSION pg_ripple does not pull it
          in and neither does CASCADE — so it has to be installed explicitly:

              CREATE EXTENSION IF NOT EXISTS pg_trickle;
        MESSAGE
      end
    end
  end
end

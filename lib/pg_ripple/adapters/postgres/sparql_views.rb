# frozen_string_literal: true

require "pg_ripple/sparql_view"
require "pg_ripple/adapters/postgres/query_executor"

module PgRipple
  module Adapters
    class Postgres
      # Fetches SPARQL views from the postgres connection.
      #
      # A SPARQL view is not a PostgreSQL view: it is a scheduled,
      # incrementally-maintained pg_trickle stream table, so `schedule` and
      # `decode` are part of the object's definition and must be dumped
      # alongside `name` and `sparql`.
      #
      # `sparql` is the query text exactly as passed to `create_sparql_view`,
      # so views round-trip. `generated_sql` and `variables` are derived — the
      # compiler rebuilds them on the next create — and `stream_table` is
      # pg_trickle's own naming, so none of the three are read here.
      #
      # `immediate`, the fifth argument to `create_sparql_view`, has no column:
      # it says whether to populate the stream table on creation, which is an
      # action rather than a property, and is therefore NOT recoverable. The
      # dumper emits the default.
      #
      # @api private
      class SparqlViews
        # The query used to retrieve the views considered dumpable into
        # `db/schema.rb`.
        SPARQL_VIEWS_QUERY = <<~SQL
          SELECT
              name,
              sparql,
              schedule,
              decode
          FROM _pg_ripple.sparql_views
          ORDER BY name;
        SQL

        # Wraps #all as a static facade.
        #
        # @return [Array<PgRipple::SparqlView>]
        def self.all(connection)
          PgRipple::Adapters::Postgres::QueryExecutor.call(
            connection: connection,
            query: SPARQL_VIEWS_QUERY,
            model_class: PgRipple::SparqlView
          )
        end
      end
    end
  end
end

# frozen_string_literal: true

require "pg_ripple/endpoint"
require "pg_ripple/adapters/postgres/query_executor"

module PgRipple
  module Adapters
    class Postgres
      # Fetches federation endpoints from the postgres connection.
      #
      # Keyed on `url`. There is no `name` anywhere in the endpoint API —
      # `register_endpoint(url, local_view_name, complexity, graph_iri)`,
      # `remove_endpoint(url)`, and `_pg_ripple.federation_endpoints` has
      # `PRIMARY KEY (url)`.
      #
      # Reads the table rather than calling `list_endpoints()`, which projects
      # only (url, enabled, local_view_name, complexity) and so would drop
      # `graph_iri` — an argument `register_endpoint` accepts and the dump has
      # to reproduce.
      #
      # Credentials are deliberately not read: `set_federation_credential`
      # stores pgcrypto-encrypted tokens in a separate catalog, and a secret
      # does not belong in a migration or a dumped schema.
      #
      # @api private
      class Endpoints
        # The query used to retrieve the endpoints considered dumpable into
        # `db/schema.rb`.
        #
        # `complexity` is decoded here. `register_endpoint` takes the hint as
        # text ('fast'/'normal'/'slow') but since v0.74.0 the column is a
        # SMALLINT (1/2/3) — the CREATE TABLE in the extension source still
        # says TEXT with a CHECK constraint, and a later ALTER changes it, so
        # the live catalog is the only reliable source. Undecoded, a dump would
        # emit `complexity: 3` and the next migration would fail. The same
        # CASE is what `list_endpoints()` applies internally.
        ENDPOINTS_QUERY = <<~SQL.freeze
          SELECT
              url,
              enabled,
              local_view_name,
              CASE complexity
                  WHEN 1 THEN 'fast'
                  WHEN 3 THEN 'slow'
                  ELSE 'normal'
              END AS complexity,
              graph_iri
          FROM _pg_ripple.federation_endpoints
          ORDER BY url;
        SQL

        # Wraps #all as a static facade.
        #
        # @return [Array<PgRipple::Endpoint>]
        def self.all(connection)
          PgRipple::Adapters::Postgres::QueryExecutor.call(
            connection: connection,
            query: ENDPOINTS_QUERY,
            model_class: PgRipple::Endpoint
          )
        end
      end
    end
  end
end

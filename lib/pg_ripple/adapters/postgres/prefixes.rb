# frozen_string_literal: true

require "pg_ripple/prefix"
require "pg_ripple/adapters/postgres/query_executor"

module PgRipple
  module Adapters
    class Postgres
      # Fetches registered namespace prefixes from the postgres connection.
      #
      # Reads `_pg_ripple.prefixes` directly. There is a
      # `pg_ripple.prefixes()` set-returning function, but it is a plain
      # `SELECT prefix, expansion FROM _pg_ripple.prefixes ORDER BY prefix` over
      # the same table, and reading the table needs no search_path assumption
      # and cannot be shadowed by a same-named relation.
      #
      # @api private
      class Prefixes
        # The prefixes pg_ripple seeds itself, as (prefix, expansion) pairs.
        #
        # `register_standard_prefixes` inserts these with ON CONFLICT DO NOTHING
        # before loading any built-in rule set, so they appear in the catalog of
        # a database no migration has touched. Dumping them would write eleven
        # `create_ripple_prefix` lines into every schema.rb that the app never
        # asked for and that pg_ripple would recreate anyway — the same reason
        # F(x) excludes extension-owned functions via pg_depend.
        #
        # Matched on BOTH columns: an app that re-registers `schema:` against
        # its own expansion has made a real schema decision, and that row is
        # dumped.
        BUILTIN_PREFIXES = {
          "rdf" => "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
          "rdfs" => "http://www.w3.org/2000/01/rdf-schema#",
          "owl" => "http://www.w3.org/2002/07/owl#",
          "xsd" => "http://www.w3.org/2001/XMLSchema#",
          "skos" => "http://www.w3.org/2004/02/skos/core#",
          "skosxl" => "http://www.w3.org/2008/05/skos-xl#",
          "dcterms" => "http://purl.org/dc/terms/",
          "dc11" => "http://purl.org/dc/elements/1.1/",
          "schema" => "https://schema.org/",
          "foaf" => "http://xmlns.com/foaf/0.1/",
          "dcat" => "http://www.w3.org/ns/dcat#"
        }.freeze

        # The query used to retrieve the prefixes considered dumpable into
        # `db/schema.rb`.
        PREFIXES_QUERY = <<~SQL
          SELECT
              prefix,
              expansion
          FROM _pg_ripple.prefixes
          ORDER BY prefix;
        SQL

        # Wraps #all as a static facade.
        #
        # @return [Array<PgRipple::Prefix>]
        def self.all(connection)
          PgRipple::Adapters::Postgres::QueryExecutor.call(
            connection: connection,
            query: PREFIXES_QUERY,
            model_class: PgRipple::Prefix
          ).reject { |prefix| builtin?(prefix) }
        end

        def self.builtin?(prefix)
          BUILTIN_PREFIXES[prefix.name] == prefix.expansion
        end
        private_class_method :builtin?
      end
    end
  end
end

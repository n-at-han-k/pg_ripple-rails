# frozen_string_literal: true

module PgRipple
  module Adapters
    class Postgres
      # Executes a catalog query and maps its rows to value objects.
      #
      # Copied from Fx::Adapters::Postgres::QueryExecutor with one change:
      # `exec_query(...).to_a` rather than `execute(...)`. `execute` hands back
      # a raw PG::Result whose every column is a String, so a boolean arrives as
      # "t"/"f" — F(x) and pg_cron never notice because their catalogs are all
      # text. Four of pg_ripple's five catalogs carry a real boolean (`active`,
      # `enabled`, `decode`), and a value object holding "f" would dump
      # `decode: "f"`, which is truthy in Ruby and would silently flip the
      # meaning of the dumped schema. `exec_query` runs the result through the
      # adapter's type map, so booleans arrive as booleans.
      #
      # @api private
      class QueryExecutor
        def self.call(...)
          new(...).call
        end

        def initialize(connection:, query:, model_class:)
          @connection = connection
          @query = query
          @model_class = model_class
        end

        # @return [Array] Array of value objects
        def call
          results_from_postgres.map { |result| model_class.new(result) }
        end

        private

        attr_reader :connection, :query, :model_class

        def results_from_postgres
          connection.exec_query(query, "pg_ripple").to_a
        end
      end
    end
  end
end

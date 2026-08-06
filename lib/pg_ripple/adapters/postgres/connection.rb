# frozen_string_literal: true

require "delegate"

module PgRipple
  module Adapters
    class Postgres
      # Decorates an ActiveRecord connection with methods that describe the
      # connection's capabilities.
      #
      # F(x) asks whether DROP FUNCTION needs an argument list; pg_cron asks
      # whether the extension is installed. This asks both extension questions,
      # because pg_ripple has two:
      #
      # * `pg_ripple` itself — nothing in `_pg_ripple.*` exists until
      #   `CREATE EXTENSION pg_ripple` has run, so every statement and every
      #   catalog read checks this first and no-ops rather than erroring.
      # * `pg_trickle` — a SOFT dependency needed only by SPARQL views. The
      #   published image ships it, but `CREATE EXTENSION pg_ripple` does not
      #   install it and `CASCADE` does not pull it in, so a database can have
      #   pg_ripple and still fail every `create_sparql_view`. `pg_ripple_enabled?`
      #   is not a sufficient guard there.
      #
      # @api private
      class Connection < SimpleDelegator
        def pg_ripple_enabled?
          extension_enabled?("pg_ripple")
        end

        def pg_trickle_enabled?
          extension_enabled?("pg_trickle")
        end

        # The installed extension version, e.g. "0.128.0", or nil when the
        # extension is absent.
        #
        # Read from `pg_extension.extversion` and NOT from
        # `_pg_ripple.schema_version`. That table is an internal
        # catalog-migration ledger — 33 rows on a fresh 0.128.0 install, top row
        # 0.98.0, all stamped within the same millisecond, so ordering by
        # installed_at is an unstable tie-break. `extversion` matches the
        # image's org.opencontainers.image.version label, so `rake
        # pg_ripple:status` and CI agree on what is installed.
        def pg_ripple_version
          query_value(<<~SQL)
            SELECT extversion FROM pg_extension WHERE extname = 'pg_ripple'
          SQL
        end
      end
    end
  end
end

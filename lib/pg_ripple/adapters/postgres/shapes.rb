# frozen_string_literal: true

require "pg_ripple/shape"
require "pg_ripple/adapters/postgres/query_executor"

module PgRipple
  module Adapters
    class Postgres
      # Fetches loaded SHACL shapes from the postgres connection.
      #
      # This is the one reader whose rows cannot be dumped back into a working
      # migration. `_pg_ripple.shacl_shapes` is
      # `(shape_iri, shape_json, active, created_at, updated_at)` — `shape_json`
      # is the PARSED shape, the Turtle that produced it is not stored, there is
      # no `export_shacl()`, and `export_turtle()` is no back door because
      # `load_shacl` never interns the shape triples in the store. So what is
      # selected here is deliberately not "enough to rebuild the shape": it is
      # enough to write the honest comment the dumper emits in place of a
      # reconstructed `load_shacl` call.
      #
      # `target` is an enum-shaped object — `{"Class": "…"}` for
      # sh:targetClass, other variants for the other target forms — so
      # `#>> '{target,Class}'` is NULL rather than wrong for a shape targeted
      # some other way, and the comment says "targets" only when it knows.
      # The property count is guarded by `jsonb_typeof` rather than left to
      # `jsonb_array_length`, which raises on a scalar — a node shape carrying
      # only node-level constraints has no `properties` array at all.
      #
      # @api private
      class Shapes
        # The query used to retrieve the shapes described in `db/schema.rb`.
        SHAPES_QUERY = <<~SQL.freeze
          SELECT
              shape_iri,
              active,
              shape_json #>> '{target,Class}' AS target_class,
              CASE
                  WHEN jsonb_typeof(shape_json -> 'properties') = 'array'
                  THEN jsonb_array_length(shape_json -> 'properties')
                  ELSE 0
              END AS property_count
          FROM _pg_ripple.shacl_shapes
          ORDER BY shape_iri;
        SQL

        # Wraps #all as a static facade.
        #
        # @return [Array<PgRipple::Shape>]
        def self.all(connection)
          PgRipple::Adapters::Postgres::QueryExecutor.call(
            connection: connection,
            query: SHAPES_QUERY,
            model_class: PgRipple::Shape
          )
        end
      end
    end
  end
end

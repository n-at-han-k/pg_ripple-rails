# frozen_string_literal: true

module PgRipple
  # Writes the pg_ripple objects that are schema into `db/schema.rb`.
  #
  # F(x)'s SchemaDumper with `functions`/`triggers` replaced by the five
  # pg_ripple kinds. Hooking `#tables` rather than `#extensions` is F(x)'s
  # choice and is load-bearing: `#extensions` is private AND redefined by the
  # PostgreSQL-specific dumper, so a module prepended to
  # `ActiveRecord::SchemaDumper` never intercepts it and the dump silently
  # comes out with no pg_ripple section at all.
  #
  # **Order: prefixes → shapes → rule sets → views → endpoints.** It is a
  # dependency order, not an alphabetical one. A SPARQL view's query is written
  # against prefixes, so the prefixes must be registered before the view is
  # compiled; an endpoint may name a local view to answer from, so the views
  # come before the endpoints. Shapes sit where they do only because they are
  # the vocabulary layer conceptually — their block is a comment and could go
  # anywhere.
  #
  # After `super` by default, for the reason the whole section is written
  # against the store the tables above it populate.
  # `dump_ripple_objects_at_beginning_of_schema` moves it before `super` for
  # F(x)'s reason: a column default that calls into the triple store needs the
  # store's objects to already exist when `db:schema:load` reaches the table.
  #
  # Every private method here carries `ripple_`. The rule is stated for
  # AbstractAdapter in {PgRipple::Statements}, and it applies with less force
  # but the same logic here: F(x) prepends a module defining a private
  # `functions`, pg_cron one defining `jobs`, and all three land on the same
  # `ActiveRecord::SchemaDumper`. A bare `shapes` or `prefixes` would be one
  # gem away from a collision.
  #
  # @api private
  module SchemaDumper
    def tables(stream)
      ripple_objects(stream) if PgRipple.configuration.dump_ripple_objects_at_beginning_of_schema

      super

      unless PgRipple.configuration.dump_ripple_objects_at_beginning_of_schema
        ripple_objects(stream)
      end
    end

    private

    # Nothing at all is written for a database with no pg_ripple objects — not
    # even the version comment. Every reader returns `[]` when the extension is
    # absent, so this is also what a database without pg_ripple gets, and a
    # `schema.rb` dumped from one is byte-identical to a `schema.rb` dumped
    # before the gem was installed.
    def ripple_objects(stream)
      prefixes = PgRipple.database.prefixes
      shapes = PgRipple.database.shapes
      rule_sets = PgRipple.database.rule_sets
      sparql_views = PgRipple.database.sparql_views
      endpoints = PgRipple.database.endpoints

      return if [prefixes, shapes, rule_sets, sparql_views, endpoints].all?(&:empty?)

      ripple_header(stream)
      ripple_prefixes(stream, prefixes)
      ripple_shapes(stream, shapes)
      ripple_rule_sets(stream, rule_sets)
      ripple_sparql_views(stream, sparql_views)
      ripple_endpoints(stream, endpoints)
    end

    # The installed version is recorded so that a schema diff shows when the
    # extension moved under the application. It is not enforced on load — v1
    # surfaces it, and `rake pg_ripple:status` reads the same value from
    # `pg_extension.extversion`.
    def ripple_header(stream)
      version = PgRipple.database.pg_ripple_version

      stream.puts
      stream.puts("  # pg_ripple objects#{", dumped from pg_ripple #{version}" if version}.")
    end

    # One-liners are dumped as a run with no blank line between them: a schema
    # with thirty prefixes reads as a block, not as thirty stanzas. The
    # multi-line kinds keep F(x)'s blank line before each.
    def ripple_prefixes(stream, prefixes)
      return if prefixes.empty?

      stream.puts
      prefixes.each { |prefix| stream.puts(prefix.to_schema) }
    end

    # The one kind that is described rather than dumped.
    #
    # `_pg_ripple.shacl_shapes` holds the PARSED shape and not the Turtle that
    # produced it; there is no `export_shacl()`; and the parse drops
    # `sh:severity`, `sh:name`, `sh:description` and `sh:order`, so even a
    # semantically-regenerated document would validate DIFFERENTLY from the
    # source. A multi-shape file is also shredded into independent rows with no
    # grouping key, so the catalog cannot supply the shape-set name a
    # `create_ripple_shapes` line needs.
    #
    # So no `create_ripple_shapes` is emitted. Emitting one would make
    # `db:schema:load` quietly build a different validation surface than the
    # migrations did, and the failure would show up as a document that
    # validates in one environment and not another. A comment cannot do that.
    #
    # `rake pg_ripple:shapes:load` replays `db/ripple/shapes` and is wired into
    # `db:schema:load`, so a schema-loaded database still ends up correct — the
    # comment says where the shapes come from, and the rake task fetches them.
    def ripple_shapes(stream, shapes)
      return if shapes.empty?

      stream.puts
      stream.puts("  # pg_ripple: #{shapes.length} SHACL #{(shapes.length == 1) ? "shape is" : "shapes are"} loaded in this database. Their source is not")
      stream.puts("  # recoverable from the catalog (see db/ripple/shapes). A database restored from")
      stream.puts("  # schema.rb alone will have no shapes — use `rake pg_ripple:shapes:load`.")
      shapes.each { |shape| stream.puts(shape.to_schema) }
    end

    def ripple_rule_sets(stream, rule_sets)
      rule_sets.each do |rule_set|
        stream.puts
        stream.puts(rule_set.to_schema)
      end
    end

    def ripple_sparql_views(stream, sparql_views)
      sparql_views.each do |sparql_view|
        stream.puts
        stream.puts(sparql_view.to_schema)
      end
    end

    def ripple_endpoints(stream, endpoints)
      return if endpoints.empty?

      stream.puts
      endpoints.each { |endpoint| stream.puts(endpoint.to_schema) }
    end
  end
end

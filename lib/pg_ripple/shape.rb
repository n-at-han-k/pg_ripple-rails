# frozen_string_literal: true

module PgRipple
  # A SHACL shape as it exists in `_pg_ripple.shacl_shapes`, and the one line
  # `db/schema.rb` can honestly say about it.
  #
  # **This is the kind that does not round-trip, and `#to_schema` returns a
  # comment rather than a migration statement because of it.**
  # `_pg_ripple.shacl_shapes` stores `shape_json` — the *parsed* shape — and
  # nothing else: the Turtle that produced it is not kept, there is no
  # `export_shacl()`, and `export_turtle()` is no back door because
  # `load_shacl` never interns the shape triples in the store.
  #
  # Regenerating Turtle from `shape_json` would be worse than useless. The
  # parse drops `sh:severity`, `sh:name`, `sh:description` and `sh:order`
  # outright, so a regenerated document would validate *differently* from the
  # source while looking like a faithful dump; and a multi-shape document is
  # shredded into one independent row per shape with no grouping key, so the
  # catalog cannot even say which definition file a shape came from — the
  # `name` that a `create_ripple_shapes` line needs does not exist here. A
  # fabricated `load_shacl` would produce a `schema.rb` that loads a different
  # validation surface than the migrations built, and would do it silently.
  #
  # So the attributes below are deliberately not "enough to rebuild the shape".
  # They are enough to tell a reader of `schema.rb` what is in the database and
  # where to go for the source. Evidence in `docs/probe-results.md` §d.
  #
  # @api private
  class Shape
    include Comparable

    attr_reader :name, :active, :target_class, :property_count

    def initialize(row)
      @name = row.fetch("shape_iri")
      @active = row.fetch("active", nil)
      @target_class = row.fetch("target_class", nil)
      @property_count = row.fetch("property_count", 0)
    end

    alias_method :shape_iri, :name

    def <=>(other)
      name <=> other.name
    end

    def ==(other)
      name == other.name
    end

    # One comment line describing this shape, for the block
    # {PgRipple::SchemaDumper} emits in place of a `create_ripple_shapes` call.
    #
    # The IRI is absolute and angle-bracketed because that is how it is stored
    # and how `drop_shape` matches it — the catalog keeps no record of the
    # prefixed name the Turtle used, so abbreviating it here would be a guess
    # at the source file's prefixes.
    #
    # "targets" is omitted rather than guessed when `target_class` is NULL:
    # `shape_json.target` is an enum-shaped object, and a shape targeted by
    # node or by subjects-of has no `Class` member at all.
    #
    # @return [String] a comment line, indented for `schema.rb`
    def to_schema
      "  #   <#{name}> (#{ripple_facts.join(", ")})"
    end

    private

    def ripple_facts
      facts = []
      facts << "targets <#{target_class}>" if target_class
      facts << "#{property_count} #{(property_count == 1) ? "property" : "properties"}"
      facts << "inactive" if active == false
      facts
    end
  end
end

# frozen_string_literal: true

module PgRipple
  # A namespace prefix as it exists in `_pg_ripple.prefixes`, and how it is
  # written back into `db/schema.rb`.
  #
  # The prefix string is the identity — `_pg_ripple.prefixes` has
  # `PRIMARY KEY (prefix)` and `register_prefix` upserts on it, so registering a
  # known prefix against a new expansion replaces it. It is exposed as `#name`
  # as well, so the value objects share one identity accessor.
  #
  # @api private
  class Prefix
    include Comparable

    attr_reader :name, :expansion

    def initialize(row)
      @name = row.fetch("prefix")
      @expansion = row.fetch("expansion")
    end

    alias_method :prefix, :name

    def <=>(other)
      name <=> other.name
    end

    def ==(other)
      name == other.name && expansion == other.expansion
    end

    # Both arguments are quoted strings rather than F(x)'s `:#{name}` symbol.
    # A function name is a PostgreSQL identifier and always survives being
    # written as a bare symbol; a namespace prefix is an arbitrary NCName and
    # may contain `-` or `.`, either of which would make `:dc-terms` a syntax
    # error in the dumped schema. {PgRipple::Statements} takes a String or a
    # Symbol everywhere, so quoting costs nothing.
    #
    # @return [String] a `create_ripple_prefix` line, indented for `schema.rb`
    def to_schema
      "  create_ripple_prefix #{name.inspect}, #{expansion.inspect}"
    end
  end
end

# frozen_string_literal: true

module PgRipple
  # A federation endpoint as it exists in `_pg_ripple.federation_endpoints`,
  # and how it is written back into `db/schema.rb`.
  #
  # The URL is the identity — the endpoint API has no name argument anywhere —
  # so it is exposed as `#name` too, matching the other value objects.
  #
  # @api private
  class Endpoint
    include Comparable

    attr_reader :name, :enabled, :local_view_name, :complexity, :graph_iri

    def initialize(row)
      @name = row.fetch("url")
      @enabled = row.fetch("enabled", nil)
      @local_view_name = row.fetch("local_view_name", nil)
      @complexity = row.fetch("complexity", nil)
      @graph_iri = row.fetch("graph_iri", nil)
    end

    alias_method :url, :name

    def <=>(other)
      name <=> other.name
    end

    def ==(other)
      name == other.name &&
        local_view_name == other.local_view_name &&
        complexity == other.complexity &&
        graph_iri == other.graph_iri
    end

    # Nil options are omitted rather than written as `nil`, so an endpoint
    # registered with nothing but a URL dumps as one argument.
    #
    # `enabled` is the one attribute that cannot be dumped. `register_endpoint`
    # upserts with `enabled = true`, pg_ripple has `disable_endpoint(url)` but
    # no `enable_endpoint`, and this gem exposes neither — so there is no pair
    # of migration methods that could express, or invert, the flag. Rather than
    # emit a call the DSL does not have, a disabled endpoint carries a comment
    # saying the rebuilt one will be enabled. Compare rule sets, where
    # `enable_rule_set`/`disable_rule_set` both exist and the flag IS dumped.
    #
    # @return [String] a `create_ripple_endpoint` line, indented for
    #   `schema.rb`
    def to_schema
      lines = ["  create_ripple_endpoint #{name.inspect}#{dumped_options}"]

      if enabled == false
        lines << "  # ^ disabled in this database. pg_ripple has disable_endpoint but no"
        lines << "  #   enable_endpoint, so the flag has no reversible migration method and"
        lines << "  #   a schema-loaded endpoint comes back enabled."
      end

      lines.join("\n")
    end

    private

    def dumped_options
      {local_view_name: local_view_name, complexity: complexity, graph_iri: graph_iri}
        .compact
        .map { |option, value| ", #{option}: #{value.inspect}" }
        .join
    end
  end
end

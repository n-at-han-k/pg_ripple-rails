# frozen_string_literal: true

require "rdf"

module PgRipple
  # The process-local prefix registry: which namespace IRIs may be abbreviated,
  # and to what.
  #
  # There are three places a prefix could have lived and only one of them works
  # for {PgRipple::Path}:
  #
  # * `_pg_ripple.prefixes` — the database's own table, which {PgRipple::Prefix}
  #   and `create_ripple_prefix` already own. Wrong for paths: `foaf.knows.to_s`
  #   would need a connection, a query and a cache invalidation strategy to
  #   render a string, and a path is a value that must be buildable in a class
  #   body at boot, before any connection exists.
  # * `RDF::Vocabulary`'s global registry — right idea, but only knows the
  #   vocabularies whose gems the host application happens to have required, and
  #   knows nothing about the application's own namespaces.
  # * Here: a small registry that the application writes to, and which *falls
  #   back* to `RDF::Vocabulary` for the well-known ones. Local registrations
  #   win, because an application's own `ex:` is authoritative over anything a
  #   vocabulary gem claims.
  #
  # A migration that runs `create_ripple_prefix "ex", "https://example.com/ns#"`
  # writes the database side; registering the same pair here is what lets the
  # path builder *print* `ex:worksAt`. They are deliberately not coupled: the
  # database mapping affects how the server parses SPARQL, this one affects what
  # this gem emits, and a query is only correct when it carries its own `PREFIX`
  # declarations regardless.
  #
  # That last point is the reason {Path#prefixes} exists. Because the fallback
  # depends on which vocabulary gems are loaded, the *same* path can render as
  # `foaf:knows` in one process and `<http://xmlns.com/foaf/0.1/knows>` in
  # another. Both are correct SPARQL only if the query carries a `PREFIX` line
  # for every prefix the path actually used — so the query builder asks the path
  # which prefixes it used rather than assuming a fixed header.
  module Prefixes
    # SPARQL 1.1 `PN_PREFIX`, conservatively: a letter, then letters, digits,
    # `_`, `-` and `.`, not ending in `.`. The empty prefix (`:name`) is legal
    # SPARQL and is allowed here too.
    PN_PREFIX = /\A(?:[A-Za-z](?:[A-Za-z0-9_\-.]*[A-Za-z0-9_-])?)?\z/

    # SPARQL 1.1 `PN_LOCAL`, conservatively. The real production admits `%`
    # escapes, backslash escapes and a much wider Unicode range; anything this
    # rejects simply renders as a full `<IRI>`, which is always valid. Being
    # narrow here costs a few characters of output and cannot produce a wrong
    # query, whereas being wide can.
    PN_LOCAL = /\A[A-Za-z0-9_](?:[A-Za-z0-9_\-.]*[A-Za-z0-9_-])?\z/

    module_function

    # Registers a prefix for this process.
    #
    # @param prefix [String, Symbol] the prefix, without the colon
    # @param expansion [String, RDF::URI] the namespace IRI
    # @return [String] the registered expansion
    # @raise [ArgumentError] if the prefix is not a legal `PN_PREFIX`
    def register(prefix, expansion)
      prefix = prefix.to_s
      unless PN_PREFIX.match?(prefix)
        raise ArgumentError, "#{prefix.inspect} is not a valid SPARQL namespace prefix"
      end

      registry[prefix] = expansion.to_s
    end

    # @return [Hash{String => String}] the prefixes registered in this process
    def registered
      registry.dup
    end

    # Forgets every locally registered prefix. Test support.
    #
    # @return [void]
    def clear!
      registry.clear
      nil
    end

    # The namespace IRI a prefix expands to, local registrations first.
    #
    # @param prefix [String, Symbol]
    # @return [String, nil]
    def expansion(prefix)
      prefix = prefix.to_s
      registry.fetch(prefix) { vocabulary_expansion(prefix) }
    end

    # Abbreviates an IRI, if any known prefix covers it.
    #
    # @param uri [RDF::URI, String]
    # @return [String, nil] `"foaf:knows"`, or nil when no prefix applies or the
    #   local part cannot be written as a `PN_LOCAL`
    def pname(uri)
      iri = uri.to_s

      local_pname(iri) || vocabulary_pname(iri)
    end

    # The prefix an IRI would be abbreviated with, if any.
    #
    # @param uri [RDF::URI, String]
    # @return [String, nil]
    def prefix_for(uri)
      pname(uri)&.split(":", 2)&.first
    end

    # A `PREFIX` declaration line for a prefix.
    #
    # @param prefix [String, Symbol]
    # @return [String]
    # @raise [KeyError] if the prefix is not registered anywhere
    def declaration(prefix)
      expansion = expansion(prefix)
      if expansion.nil?
        raise KeyError, "no expansion registered for the prefix #{prefix.to_s.inspect}"
      end

      "PREFIX #{prefix}: #{RDF::URI(expansion).to_base}"
    end

    # `PREFIX` declarations for a set of prefixes, one per line, sorted.
    #
    # @param prefixes [Enumerable<String>]
    # @return [String] the empty string when there are none
    def declarations(prefixes)
      lines = prefixes.to_a.uniq.sort.map { |prefix| declaration(prefix) }
      return "" if lines.empty?

      lines.join("\n") << "\n"
    end

    # @api private
    def registry
      @registry ||= {}
    end

    # @api private
    def local_pname(iri)
      # Longest expansion first: an application that registers both
      # `https://example.com/` and `https://example.com/hr/` means the second
      # one for `https://example.com/hr/manages`.
      registry
        .sort_by { |_prefix, expansion| -expansion.length }
        .each do |prefix, expansion|
          next unless iri.start_with?(expansion)

          local = iri[expansion.length..]
          return "#{prefix}:#{local}" if PN_LOCAL.match?(local)
        end

      nil
    end

    # @api private
    def vocabulary_pname(iri)
      vocabulary = RDF::Vocabulary.find(RDF::URI(iri))
      return nil if vocabulary.nil?

      prefix = vocabulary.__prefix__.to_s
      return nil unless PN_PREFIX.match?(prefix)

      local = iri[vocabulary.to_uri.to_s.length..]
      return nil unless local && PN_LOCAL.match?(local)

      "#{prefix}:#{local}"
    end

    # @api private
    def vocabulary_expansion(prefix)
      vocabulary = RDF::Vocabulary.each.find { |vocab| vocab.__prefix__.to_s == prefix }
      vocabulary&.to_uri&.to_s
    end
  end
end

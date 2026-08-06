# frozen_string_literal: true

require "rdf"

require "pg_ripple/path"
require "pg_ripple/prefixes"
require "pg_ripple/term"

module PgRipple
  # A SPARQL `SELECT ?iri` built from terms, never from text.
  #
  # This is the query on the *graph* side of a graph-backed
  # `ActiveRecord::Relation`. It projects exactly one variable — the subject —
  # because the only thing SQL wants back from pg_ripple is the join key: which
  # rows of the table this traversal reached. Everything a caller might want to
  # *display* is already in the table, and a graph value projected into a SQL
  # predicate is a runtime error rather than a cast
  # (`docs/probe-lateral-join.md` §d).
  #
  # Three properties of the rendered query are load-bearing and none of them
  # are in the README's example SQL:
  #
  # - **`DISTINCT`.** A property path with more than one route between the same
  #   two nodes yields the same `?iri` once per route, and each of those
  #   solutions joins to the same table row. Without `DISTINCT` a `+` path
  #   silently returns duplicate records.
  # - **`LIMIT`/`OFFSET` are part of the query, not of the SQL around it.**
  #   `pg_ripple.sparql()` materialises every solution before PostgreSQL sees
  #   row 1, so an outer `LIMIT` truncates a result that has already been
  #   computed in full — measured at 40× on a 25 921-solution query
  #   (`docs/probe-lateral-join.md` §b). {PgRipple::Relation} decides when
  #   pushing one down here is *sound*; this class only renders what it is
  #   given. They are fields rather than text appended to a finished query, so
  #   there is no case in which a second `LIMIT` can be concatenated onto a
  #   first.
  # - **`PREFIX` lines come from the paths.** Whether a path renders
  #   `foaf:knows` or `<http://xmlns.com/foaf/0.1/knows>` depends on what the
  #   host application registered, so the header is asked for rather than
  #   assumed (`docs/spec-corrections.md` §8).
  #
  # @api private
  class Query
    # The projected variable, and the key the lateral join reads out of the
    # `result` JSONB.
    SUBJECT = "iri"

    # A generated variable name has to be a name SPARQL accepts. Property names
    # come from a class body rather than from user input, but a name is the one
    # thing that cannot be escaped, only refused.
    VARIABLE_NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/

    # @return [RDF::URI, nil] the named graph the patterns are wrapped in
    attr_reader :graph_name

    # @return [Integer, nil]
    attr_reader :limit, :offset

    # @return [Boolean] whether the solutions are ordered by subject
    attr_reader :ordered

    def initialize(graph_name: nil)
      @graph_name = graph_name.nil? ? nil : RDF::URI(PgRipple::Term.graph_argument(graph_name))
      @lines = []
      @paths = []
      @variables = [SUBJECT]
      @limit = nil
      @offset = nil
      @ordered = false
    end

    def initialize_copy(other)
      super
      @lines = other.instance_variable_get(:@lines).dup
      @paths = other.instance_variable_get(:@paths).dup
      @variables = other.instance_variable_get(:@variables).dup
    end

    # @return [Boolean] whether anything at all has been stated
    def empty?
      @lines.empty?
    end

    # A copy of this query, asking the same thing of a named graph.
    #
    # @param graph_name [String, RDF::URI, nil]
    # @return [PgRipple::Query]
    def with_graph_name(graph_name)
      copy = dup
      copy.instance_variable_set(
        :@graph_name,
        graph_name.nil? ? nil : RDF::URI(PgRipple::Term.graph_argument(graph_name))
      )
      copy
    end

    # `?iri a <Type> .`
    #
    # @param type [RDF::URI]
    # @return [self]
    def type(type)
      @lines << "#{subject} a #{PgRipple::Term.sparql(RDF::URI.intern(type))} ."
      self
    end

    # A triple with the subject variable in the object position.
    #
    # This is the traversal a graph association compiles to: the subject is
    # *known* (the owner record), so the SPARQL text does not depend on any
    # SQL column and the lateral is uncorrelated — evaluated once for the whole
    # query rather than once per outer row (`docs/probe-lateral-join.md` §c).
    #
    # @param from [RDF::Term] the owner's subject IRI
    # @param path [PgRipple::Path]
    # @return [self]
    def traverse(from:, path:)
      @paths << path
      @lines << "#{PgRipple::Term.sparql(from)} #{path} #{subject} ."
      self
    end

    # `?iri <predicate> <value> .`
    #
    # @param path [PgRipple::Path]
    # @param value [RDF::Term]
    # @return [self]
    def equal(path, value)
      @paths << path
      @lines << "#{subject} #{path} #{PgRipple::Term.sparql(value)} ."
      self
    end

    # `?iri <predicate> ?v .` — binds a variable so a FILTER can compare it.
    #
    # @param path [PgRipple::Path]
    # @param name [String] a preferred variable name
    # @return [String] the variable actually bound
    def bind(path, name)
      variable = fresh_variable(name)
      @paths << path
      @lines << "#{subject} #{path} ?#{variable} ."
      variable
    end

    # `FILTER(…)`
    #
    # @param expression [String] built from {PgRipple::Term.sparql}-escaped
    #   pieces by the caller
    # @return [self]
    def filter(expression)
      @lines << "FILTER(#{expression})"
      self
    end

    # `FILTER NOT EXISTS { ?iri <predicate> … }`
    #
    # The rendering of both `where(role: nil)` and `where.not(role: "x")`. For
    # the second it is not merely one reading of "not" among several: a graph
    # property is a *set*, so `FILTER(?role != "contractor")` is satisfied by a
    # subject that is a contractor and something else as well. `NOT EXISTS` is
    # the only form that means what `where.not` says.
    #
    # @param path [PgRipple::Path]
    # @param value [RDF::Term, nil] nil to match the property's mere presence
    # @return [self]
    def not_exists(path, value = nil)
      @paths << path
      object = value.nil? ? "?#{fresh_variable("o")}" : PgRipple::Term.sparql(value)
      @lines << "FILTER NOT EXISTS { #{subject} #{path} #{object} }"
      self
    end

    # Orders the solutions by subject.
    #
    # Only {PgRipple::Relation#find_each} asks for this, and it needs it: a
    # SPARQL query with no `ORDER BY` has no defined solution order, so paging
    # it with `LIMIT`/`OFFSET` could visit a subject twice and another never.
    #
    # @return [self]
    def order_by_subject
      @ordered = true
      self
    end

    # @param limit [Integer, nil]
    # @param offset [Integer, nil]
    # @return [self]
    def slice(limit: nil, offset: nil)
      @limit = limit
      @offset = offset
      self
    end

    # @return [String] the SPARQL SELECT
    def to_s
      +"" << prefix_declarations << "SELECT DISTINCT #{subject}\nWHERE #{group}" << tail
    end

    # @return [Array<String>] the prefixes the rendered paths used
    def prefixes
      @paths.flat_map(&:prefixes).uniq.sort
    end

    private

    def subject
      "?#{SUBJECT}"
    end

    def prefix_declarations
      PgRipple::Prefixes.declarations(prefixes)
    end

    def group
      body = @lines.map { |line| "  #{line}\n" }.join
      return "{\n#{body}}\n" if graph_name.nil?

      "{\n  GRAPH #{PgRipple::Term.sparql(graph_name)} {\n#{body.gsub(/^/, "  ")}  }\n}\n"
    end

    def tail
      parts = []
      parts << "ORDER BY #{subject}" if ordered
      parts << "LIMIT #{Integer(limit)}" if limit
      parts << "OFFSET #{Integer(offset)}" if offset
      return "" if parts.empty?

      parts.join("\n") << "\n"
    end

    # A variable name not already in use, derived from a caller's preference.
    def fresh_variable(preferred)
      base = preferred.to_s
      base = "v" unless base.match?(VARIABLE_NAME)

      candidate = base
      suffix = 1
      while @variables.include?(candidate)
        candidate = "#{base}_#{suffix}"
        suffix += 1
      end

      @variables << candidate
      candidate
    end
  end
end

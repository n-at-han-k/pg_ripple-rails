# frozen_string_literal: true

require "json"
require "rdf"

require "pg_ripple/persistence"
require "pg_ripple/term"

module PgRipple
  # An {RDF::Repository} whose storage is pg_ripple, over the application's own
  # ActiveRecord connection.
  #
  # No second connection and no second pool. That is not a convenience: it is
  # what makes a triple write and a row write the same transaction, so the
  # transactional fixture that rolls a test's rows back rolls its triples back
  # too, and a `raise ActiveRecord::Rollback` after a successful graph write
  # takes the graph write with it.
  #
  # **Whole queries go to the server.** {RDF::Queryable} answers a basic graph
  # pattern by default through `RDF::Query#execute`, which walks the query one
  # `query_pattern` call at a time and joins the results in Ruby — a plan whose
  # every intermediate crosses the wire. Overriding {#query_execute} is what
  # stops that: the BGP is rendered as one SPARQL query and pg_ripple plans and
  # joins it. It is also why the README says not to wrap this in
  # `SPARQL::Client.new(repo)` — the client's `RDF::Queryable` mode reintroduces
  # exactly the per-pattern evaluation this override exists to avoid.
  #
  # **Scoped to one graph.** `nil` means the default graph, which is what
  # {PgRipple::Configuration#default_graph} defaults to. A repository over a
  # named graph reads, writes and counts only that graph, so
  # `supports?(:graph_name)` is false and a statement carrying a different graph
  # is refused rather than silently written somewhere else. Ask for a second
  # graph by asking for a second repository.
  #
  # @example
  #   repo = PgRipple.repository
  #   repo << [alice.rdf_subject, RDF::Vocab::FOAF.knows, bob.rdf_subject]
  #   repo.query([nil, RDF::Vocab::FOAF.name, nil]).each { |st| puts st }
  #   repo.count
  class Repository < RDF::Repository
    # A SPARQL variable name this gem is willing to write into a query.
    #
    # The check is not defensive quoting — a variable name cannot be escaped,
    # only rejected — it is a guard on the one place where a Ruby symbol
    # becomes SPARQL syntax. RDF::Query variables usually come from a parser and
    # are already fine; the ones that are not are the generated, non-round-trip
    # names, and for those {#query_execute} falls back to RDF.rb's own
    # evaluation rather than emitting something it cannot escape.
    VARIABLE_NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/

    # The two set-returning functions that answer a SELECT with
    # `TABLE(result jsonb)`. Both take the query as a bind parameter; the
    # function name is the only part of the SQL this class assembles, and it can
    # only ever be one of these.
    SOLUTION_FUNCTIONS = %w[sparql sparql_cursor].freeze

    # The named graph this repository is scoped to, or nil for the default
    # graph.
    #
    # @return [RDF::URI, nil]
    attr_reader :graph_name

    # @param graph_name [String, RDF::URI, nil] the named graph to scope to.
    #   Omitted, it comes from {PgRipple::Configuration#default_graph}.
    # @param connectable [#connection] the object the ActiveRecord connection is
    #   taken from. Swappable for a test, not for a second database: pg_ripple
    #   is only transactional with the application's writes on the connection
    #   the application is already using.
    def initialize(graph_name: :configured, connectable: ActiveRecord::Base, **options)
      graph_name = PgRipple.configuration.default_graph if graph_name == :configured

      @graph_name = graph_name.nil? ? nil : RDF::URI(PgRipple::Term.graph_argument(graph_name))
      @connectable = connectable

      super(**options, with_graph_name: false)
    end

    # Runs a SPARQL SELECT and returns its solutions.
    #
    # The escape hatch: a query this gem's own builders cannot express goes
    # through here as text, and comes back as the same {RDF::Query::Solution}s
    # everything else returns.
    #
    # Named `#sparql` and not `#select` because {RDF::Enumerable} includes
    # Ruby's own Enumerable, where `select` means `filter` — the module-level
    # {PgRipple.select} the README documents is a different receiver with no
    # such neighbour.
    #
    # @param query [String] a SPARQL SELECT query
    # @return [RDF::Query::Solutions]
    def sparql(query, &block)
      solutions = RDF::Query::Solutions.new

      each_solution(query) do |solution|
        solutions << solution
        block&.call(solution)
      end

      solutions
    end

    # Runs a SPARQL SELECT through pg_ripple's cursor.
    #
    # `sparql_cursor()` has the same signature and the same
    # `TABLE(result jsonb)` shape as `sparql()`, and opens a portal over the
    # generated SQL instead of materialising every solution's JSONB at once
    # (`docs/probe-lateral-join.md` §f). That bounds peak *memory*, not latency:
    # the query still runs to completion before the first page arrives, so this
    # is the right primitive for {PgRipple::Relation#find_each} and the wrong
    # one for making a `LIMIT` cheap.
    #
    # @param query [String] a SPARQL SELECT query
    # @return [RDF::Query::Solutions]
    def sparql_cursor(query, &block)
      solutions = RDF::Query::Solutions.new

      each_solution(query, function: "sparql_cursor") do |solution|
        solutions << solution
        block&.call(solution)
      end

      solutions
    end

    # pg_ripple's plan for a SPARQL query.
    #
    # Two overloads exist on the server: `explain_sparql(query, format text)`
    # returning text and `explain_sparql(query, analyze boolean)` returning
    # JSONB. They are distinguished by the *type* of the second argument, so it
    # is cast explicitly rather than sent untyped — an untyped parameter here is
    # an ambiguous-function error, not a coin toss.
    #
    # @param query [String]
    # @param analyze [Boolean] run the query and report what happened
    # @param format [String] `"text"` or `"json"`, when not analyzing
    # @return [String, Object]
    def explain_sparql(query, analyze: false, format: "text")
      return scalar("SELECT pg_ripple.explain_sparql($1::text, $2::text)", query, format) unless analyze

      result = scalar("SELECT pg_ripple.explain_sparql($1::text, $2::boolean)", query, true)
      result.is_a?(String) ? JSON.parse(result) : result
    end

    # Runs a SPARQL ASK.
    #
    # `sparql_ask()` rather than `sparql()`, which answers an ASK with
    # `{"result": "true"}` — a JSON string, under a key that collides with the
    # name of the column it arrives in (`docs/probe-lateral-join.md` §d).
    # `sparql_ask()` returns a boolean and has neither problem.
    #
    # @param query [String] a SPARQL ASK query
    # @return [Boolean]
    def ask(query)
      ActiveModel::Type::Boolean.new.cast(
        scalar("SELECT pg_ripple.sparql_ask($1::text)", query)
      )
    end

    # Runs a SPARQL Update.
    #
    # `sparql_update()` runs in the caller's transaction — no autonomous
    # transaction, no deferred worker — so a `raise ActiveRecord::Rollback`
    # after this call takes the graph write with it and a SQL error after it
    # retracts it (`docs/probe-lateral-join.md` §e). That is what makes the
    # README's "Transactions" section true without a single compensating
    # delete.
    #
    # Not named `#update`: {RDF::Mutable#update} already means "replace the
    # statements with these", and a method that took SPARQL text under that
    # name would be a trap for anything treating this as an ordinary
    # repository.
    #
    # @param update [String] a SPARQL 1.1 Update request. Build it with
    #   {PgRipple::Persistence::Update} rather than by hand.
    # @return [Integer] triples affected
    def sparql_update(update)
      scalar("SELECT pg_ripple.sparql_update($1::text)", update).to_i
    end

    # The number of statements in this repository's graph.
    #
    # Counted by scanning rather than through `pg_ripple.triple_count()`, which
    # is a sum over `_pg_ripple.predicates` across *every* graph and so would
    # disagree with {#each_statement} on any database that has a named graph in
    # it. `triple_count_in_graph()` is graph-aware but reads only the dedicated
    # VP tables and misses `vp_rare`, which is where an infrequent predicate
    # lives. A count that does not match what enumeration yields is worse than a
    # slow one; {RDF::Countable} is entitled to expect the two to agree.
    #
    # @return [Integer]
    def count
      if graph_name
        scalar(
          "SELECT count(*) FROM pg_ripple.find_triples_in_graph(NULL, NULL, NULL, $1::text)",
          PgRipple::Term.graph_argument(graph_name)
        ).to_i
      else
        scalar("SELECT count(*) FROM pg_ripple.find_triples(NULL, NULL, NULL)").to_i
      end
    end

    # Yields every statement in this repository's graph.
    #
    # @yieldparam [RDF::Statement]
    # @return [Enumerator, void]
    def each_statement(&block)
      return enum_statement unless block_given?

      each_found_statement(nil, nil, nil, &block)
    end
    alias_method :each, :each_statement

    # @see RDF::Repository#supports?
    def supports?(feature)
      case feature.to_sym
      when :graph_name then false
      else super
      end
    end

    protected

    # @see RDF::Writable#insert_statement
    def insert_statement(statement)
      assert_in_scope!(statement)

      if graph_name
        execute(
          "SELECT pg_ripple.insert_triple($1::text, $2::text, $3::text, $4::text)",
          *serialize_spo(statement), PgRipple::Term.graph_argument(graph_name)
        )
      else
        execute(
          "SELECT pg_ripple.insert_triple($1::text, $2::text, $3::text)",
          *serialize_spo(statement)
        )
      end

      PgRipple::Persistence.notify(inserted: [statement], graph_name: graph_name)
    end

    # @see RDF::Mutable#delete_statement
    def delete_statement(statement)
      assert_in_scope!(statement)

      if graph_name
        execute(
          "SELECT pg_ripple.delete_triple_from_graph($1::text, $2::text, $3::text, $4::text)",
          *serialize_spo(statement), PgRipple::Term.graph_argument(graph_name)
        )
      else
        execute(
          "SELECT pg_ripple.delete_triple($1::text, $2::text, $3::text)",
          *serialize_spo(statement)
        )
      end

      PgRipple::Persistence.notify(deleted: [statement], graph_name: graph_name)
    end

    # Answers a single triple pattern.
    #
    # `find_triples` rather than a one-pattern SPARQL query: it takes the bound
    # positions as arguments and NULL as a wildcard, which is the same question
    # without a parse, a plan and a JSONB object per solution.
    #
    # @see RDF::Queryable#query_pattern
    def query_pattern(pattern, **options, &block)
      return enum_for(:query_pattern, pattern, **options) unless block_given?

      subject, predicate, object = [pattern.subject, pattern.predicate, pattern.object].map do |term|
        (term.nil? || term.variable?) ? nil : PgRipple::Term.serialize(term)
      end

      each_found_statement(subject, predicate, object, &block)
    end

    # Answers a whole basic graph pattern with one SPARQL query.
    #
    # Falls back to {RDF::Queryable}'s pattern-at-a-time evaluation for the
    # queries SPARQL cannot state. There are two, and neither is a limitation of
    # this gem: a pattern holding a specific blank node is asking to match one
    # identified node, where a `_:b` in a SPARQL query means a fresh variable;
    # and patterns spread across more than one named graph are outside a
    # single-graph repository's scope. Falling back is slower and correct, which
    # is the right way round.
    #
    # @see RDF::Queryable#query_execute
    def query_execute(query, **options, &block)
      scope = graph_scope(query)
      return super if scope == :unsupported
      return super unless expressible?(query)

      variables = projected_variables(query, scope)

      if variables.empty?
        yield RDF::Query::Solution.new({}) if ask(ask_query(query, scope))
        return
      end

      each_solution(select_query(query, scope, variables), &block)
    end

    private

    attr_reader :connectable

    # Raises rather than writing a quad to the wrong graph.
    #
    # `supports?(:graph_name)` is already false, but nothing in RDF.rb enforces
    # that on the way into {#insert_statement}, and the failure it would cause —
    # a triple written to the default graph because that is what this repository
    # is scoped to, and then not found by a reader looking in the graph the
    # statement named — is silent.
    def assert_in_scope!(statement)
      return if statement.graph_name.nil?
      return if statement.graph_name == graph_name

      raise ArgumentError, <<~MESSAGE.strip
        #{self.class} is scoped to #{graph_name ? graph_name.to_s : "the default graph"}
        and cannot write a statement in #{statement.graph_name}.

        Ask for a repository over that graph instead:

            PgRipple.repository(graph_name: #{statement.graph_name.to_s.inspect})
      MESSAGE
    end

    def serialize_spo(statement)
      [statement.subject, statement.predicate, statement.object].map do |term|
        PgRipple::Term.serialize(term)
      end
    end

    def each_found_statement(subject, predicate, object)
      rows =
        if graph_name
          query_rows(
            "SELECT s, p, o FROM pg_ripple.find_triples_in_graph($1::text, $2::text, $3::text, $4::text)",
            subject, predicate, object, PgRipple::Term.graph_argument(graph_name)
          )
        else
          query_rows(
            "SELECT s, p, o FROM pg_ripple.find_triples($1::text, $2::text, $3::text)",
            subject, predicate, object
          )
        end

      rows.each do |(s, p, o)|
        yield RDF::Statement.new(
          PgRipple::Term.parse(s),
          PgRipple::Term.parse(p),
          PgRipple::Term.parse(o),
          graph_name: graph_name
        )
      end
    end

    # Runs a SPARQL SELECT and yields a solution per row.
    #
    # Every binding is an N-Triples term string under the variable's own name,
    # and an unbound variable is present with a JSON null, so the decode is
    # {PgRipple::Term.parse} over the object's values with the nulls dropped —
    # a solution binds what is bound and says nothing about the rest.
    def each_solution(sparql, function: "sparql")
      # `function` is one of this class's own literals — `sparql` or
      # `sparql_cursor` — never anything a caller supplied. The query itself is
      # bound.
      raise ArgumentError, "unknown function #{function}" unless SOLUTION_FUNCTIONS.include?(function)

      query_rows("SELECT result FROM pg_ripple.#{function}($1::text)", sparql).each do |(result)|
        bindings = (result.is_a?(String) ? JSON.parse(result) : result)
          .filter_map { |name, term| [name.to_sym, PgRipple::Term.parse(term)] unless term.nil? }
          .to_h

        yield RDF::Query::Solution.new(bindings)
      end
    end

    # The graph an {RDF::Query} is asking about, reconciled with this
    # repository's scope.
    #
    # `nil` is "unstated", so the repository's own scope applies; `false` is
    # RDF.rb's marker for the default graph and overrides the scope. More than
    # one stated graph is a query this repository cannot answer.
    #
    # @return [RDF::URI, nil, :unsupported]
    def graph_scope(query)
      stated = ([query.graph_name] + query.patterns.map(&:graph_name)).uniq
      stated.delete(nil)

      return :unsupported if stated.size > 1

      case stated.first
      when nil then graph_name
      when false then nil
      else stated.first
      end
    end

    # Whether every term in the query can be written as SPARQL.
    def expressible?(query)
      return false if query.patterns.empty?

      terms = query.patterns.flat_map { |pattern| [pattern.subject, pattern.predicate, pattern.object] }
      terms << query.graph_name if query.graph_name.is_a?(RDF::Term)

      terms.all? do |term|
        case term
        when nil then false
        when RDF::Query::Variable then term.name.to_s.match?(VARIABLE_NAME)
        when RDF::Node then false
        else true
        end
      end
    end

    def projected_variables(query, scope)
      names = query.variables.keys.map(&:to_s)
      names << scope.name.to_s if scope.is_a?(RDF::Query::Variable)
      names.uniq
    end

    def select_query(query, scope, variables)
      projection = variables.map { |name| "?#{name}" }.join(" ")

      "SELECT #{projection} WHERE #{group(query, scope)}"
    end

    def ask_query(query, scope)
      "ASK WHERE #{group(query, scope)}"
    end

    # The `WHERE { … }` group, wrapped in a `GRAPH` block when the query is
    # about a named graph.
    def group(query, scope)
      body = patterns_body(query)

      return "{\n#{body}}\n" if scope.nil?

      "{\n  GRAPH #{sparql_term(scope)} {\n#{body.gsub(/^/, "  ")}  }\n}\n"
    end

    # Required patterns first, then the optional ones.
    #
    # Order matters in SPARQL in a way it does not in an {RDF::Query}: an
    # `OPTIONAL` extends the group to its left, so an optional emitted before
    # the pattern it depends on binds nothing.
    def patterns_body(query)
      required, optional = query.patterns.partition { |pattern| !pattern.optional? }

      lines = required.map { |pattern| "  #{triple(pattern)}\n" }
      lines += optional.map { |pattern| "  OPTIONAL { #{triple(pattern)} }\n" }

      lines.join
    end

    def triple(pattern)
      "#{sparql_term(pattern.subject)} #{sparql_term(pattern.predicate)} #{sparql_term(pattern.object)} ."
    end

    # A term as SPARQL text.
    #
    # Constants go through the N-Triples writer, which escapes; variables are
    # the only thing written literally, and {#expressible?} has already checked
    # every one of them against {VARIABLE_NAME}.
    def sparql_term(term)
      return "?#{term.name}" if term.is_a?(RDF::Query::Variable)

      PgRipple::Term.serialize(term)
    end

    # `#lease_connection`, not `#connection`.
    #
    # `ActiveRecord::Base.connection` is the deprecated permanent-checkout API.
    # An application that has set `permanent_connection_checkout = :disallowed`
    # — the setting Rails is moving towards — gets
    # `ActiveRecordError: Called deprecated 'ActiveRecord::Base.connection'`
    # from *every* graph read and write, including from inside its own
    # `with_connection` block, so there is no way to scope around it; with
    # `:deprecated` it pins a pool connection to the thread for the process
    # lifetime. `#lease_connection` is the same lease with none of that.
    #
    # It has to be a lease rather than a `with_connection` block: pg_ripple is
    # only transactional with the application's own writes when it runs on the
    # connection the application is already using, and a block would be free to
    # hand back a different one.
    #
    # Falls back on Rails 7.1, where `#lease_connection` does not exist yet and
    # `#connection` is not deprecated.
    def connection
      return connectable.lease_connection if connectable.respond_to?(:lease_connection)

      connectable.connection
    end

    # Values are bound, never interpolated — a SPARQL query is full of quotes
    # and full of `$`, and a literal in a triple can contain anything at all.
    # Sent as text and cast in the SQL, so one code path covers strings and
    # NULLs and no untyped parameter has to be resolved against an overload.
    def binds_for(values)
      values.map.with_index(1) do |value, position|
        ActiveRecord::Relation::QueryAttribute.new(
          "$#{position}",
          value&.to_s,
          ActiveRecord::Type::Value.new
        )
      end
    end

    def query_rows(sql, *values)
      connection.exec_query(sql, "pg_ripple", binds_for(values)).rows
    end

    def scalar(sql, *values)
      query_rows(sql, *values).dig(0, 0)
    end

    def execute(sql, *values)
      connection.exec_update(sql, "pg_ripple", binds_for(values))
    end
  end
end

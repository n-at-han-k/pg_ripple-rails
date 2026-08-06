# frozen_string_literal: true

require "digest"

require "active_record"
require "rdf"

require "pg_ripple/query"
require "pg_ripple/term"

module PgRipple
  # A graph query that is on its way to becoming an `ActiveRecord::Relation`.
  #
  # `Person.graph` returns one of these. It is a *builder*, not a relation:
  # `#where` on it means "filter by a graph predicate", which is the one thing
  # an `ActiveRecord::Relation` cannot be taught without breaking `#where` for
  # the columns. Everything else — `#order`, `#includes`, `#count`, `#page`,
  # `#each` — falls through {#method_missing} to the relation and from there on
  # you are in ordinary ActiveRecord, which is the point.
  #
  #     Person.graph.where(role: "engineer")            # PgRipple::Relation
  #     Person.graph.where(role: "engineer").order(:name)  # ActiveRecord::Relation
  #
  # It composes with ordinary scopes in both directions.
  # `Person.where(active: true).graph` works because ActiveRecord delegates an
  # unknown relation method to the class inside `scoping`, so the `Person.all`
  # this captures is the scope you were already in.
  #
  # ### How the traversal reaches SQL
  #
  # As a `JOIN LATERAL` over `pg_ripple.sparql()`, which returns
  # `TABLE(result jsonb)` — so the join projects the subject out of the JSONB
  # rather than taking a column definition list, and unwraps the N-Triples
  # angle brackets the binding arrives in (`docs/spec-corrections.md` §1 as
  # amended by `docs/probe-lateral-join.md` §a). The SPARQL is a **bind
  # parameter**, not interpolated text: it is full of quotes and can contain any
  # literal a user ever wrote.
  #
  # The lateral is deliberately *uncorrelated* — the subject is bound when the
  # query is built, never taken from an outer column — so PostgreSQL evaluates
  # it once for the whole query instead of once per row (§c).
  class Relation
    # The `#where` receiver that `#not` hangs off.
    #
    #     Person.graph.where.not(role: "contractor")
    class WhereChain
      # @api private
      def initialize(relation)
        @relation = relation
      end

      # @param conditions [Hash]
      # @return [PgRipple::Relation]
      def not(conditions)
        @relation.send(:build) { |query, scope| @relation.send(:apply_not, query, scope, conditions) }
      end
    end

    # A bound SQL literal that ActiveRecord can also read as text.
    #
    # The traversal has to reach SQL as a `JOIN LATERAL` carrying the SPARQL as
    # a *bind*, and Arel's `BoundSqlLiteral` is exactly that. But
    # `ActiveRecord::Relation#references_eager_loaded_tables?` — reached by any
    # `includes`, which is the README's own example line — inspects a
    # `StringJoin`'s left side with `String#scan` to find out which tables the
    # join names. A `BoundSqlLiteral` is not a String and raises `NoMethodError`
    # there.
    #
    # Two methods over the *template* (the text with `?` still in it) settle it:
    # the placeholder is not a table name, so the answer is the same one a
    # plain string join would have given, and the values still travel as binds.
    class BoundJoin < Arel::Nodes::BoundSqlLiteral
      def blank?
        sql_with_placeholders.blank?
      end

      def scan(...)
        sql_with_placeholders.scan(...)
      end
    end

    # What every lateral's alias starts with, and the marker
    # {PgRipple::PlanCache::Invalidation} recognises a traversal by.
    ALIAS_PREFIX = "pg_ripple_graph_"

    class << self
      # Attaches a graph traversal to an `ActiveRecord::Relation`.
      #
      # The one place this gem emits SQL of its own, and the reason it is a
      # class method: {PgRipple::Associations} needs exactly this and nothing
      # else around it.
      #
      # @param scope [ActiveRecord::Relation]
      # @param sparql [String]
      # @return [ActiveRecord::Relation]
      def attach(scope, sparql)
        model = scope.model
        table = model.quoted_table_name
        # The column name is this gem's own constant rather than anything a
        # caller supplied, so it is quoted rather than escaped — and quoting it
        # here keeps `attach` from needing a connection.
        column = %("#{iri_column(model)}")
        name = join_alias(sparql)

        # `btrim(…, '<>')` is not cosmetic: an IRI binding arrives as the
        # N-Triples term `"<https://…>"`, so the join written without it runs
        # clean and matches nothing (`docs/probe-lateral-join.md` §a).
        literal = BoundJoin.new(<<~SQL, [sparql], nil)
          JOIN LATERAL (
            SELECT btrim(r.result ->> '#{Query::SUBJECT}', '<>') AS #{Query::SUBJECT}
            FROM pg_ripple.sparql(?::text) AS r
          ) AS #{name} ON #{name}.#{Query::SUBJECT} = #{table}.#{column}
        SQL

        scope.joins(Arel::Nodes::StringJoin.new(literal))
      end

      # Whether a piece of SQL is one of {.attach}'s laterals.
      #
      # Asked by {PgRipple::PlanCache::Invalidation} of every statement the
      # PostgreSQL adapter runs, because a traversal reaches the server through
      # ActiveRecord's own query path and never through
      # {PgRipple::ConnectionLeasing} — see {PgRipple::PlanCache.around_statement}.
      #
      # {ALIAS_PREFIX} rather than `"pg_ripple"`, and that is the whole reason
      # the alias has a prefix worth naming: `pg_ripple.plan_cache_reset()` is
      # itself pg_ripple SQL, and a test that matched it would recurse — the
      # reset would look like a statement that needs a reset. Nothing but this
      # gem's own lateral ever spells {ALIAS_PREFIX}.
      #
      # @param sql [String]
      # @return [Boolean]
      def lateral?(sql)
        sql.is_a?(String) && sql.include?(ALIAS_PREFIX)
      end

      # The lateral's alias, derived from the traversal it runs.
      #
      # Counting the joins already on the scope does not work: every graph
      # association attaches to a *fresh* `target.all`, which has none, so
      # `alice.friends` and `alice.network` both named their lateral
      # `pg_ripple_graph_0` and merging them — ordinary ActiveRecord on two
      # ordinary relations — died with `PG::DuplicateAlias`.
      #
      # A digest of the SPARQL settles it in both directions. Two different
      # traversals get two different aliases, so the merge is valid SQL; two
      # *identical* traversals get the same alias and the same `StringJoin`,
      # which `#joins!` (`self.joins_values |= args`) then deduplicates into
      # one join rather than colliding. It is also stable across calls, so
      # `#to_sql` is comparable and the statement cache still works.
      #
      # @param sparql [String]
      # @return [String]
      def join_alias(sparql)
        "#{ALIAS_PREFIX}#{Digest::SHA256.hexdigest(sparql)[0, 16]}"
      end

      # @param model [Class]
      # @return [String] the column holding the subject IRI
      def iri_column(model)
        unless model.column_names.include?(Query::SUBJECT)
          raise PgRipple::IriError,
            "#{model.name} has no #{Query::SUBJECT} column; add one with " \
            "`add_column :#{model.table_name}, :#{Query::SUBJECT}, :string`"
        end

        Query::SUBJECT
      end
    end

    # @return [Class] the ActiveRecord model
    attr_reader :model

    # @return [PgRipple::Query]
    attr_reader :query

    # @param model [Class]
    # @param scope [ActiveRecord::Relation] the SQL half, as it stands
    # @param query [PgRipple::Query] the graph half
    # @api private
    def initialize(model, scope: nil, query: nil)
      @model = model
      @scope = scope || model.all
      @query = query || default_query
    end

    # Filters by graph predicates, or by columns.
    #
    # A name that names a declared graph property is a SPARQL pattern; a name
    # that names only a column is handed to ActiveRecord unchanged, so
    # `Person.graph.where(role: "engineer", active: true)` is one query with one
    # of each. A name that is neither raises, which is what makes a typo a test
    # failure rather than an empty result.
    #
    # Values:
    #
    # | Ruby | SPARQL |
    # | --- | --- |
    # | `"engineer"` | `?iri ex:role "engineer" .` |
    # | `nil` | `FILTER NOT EXISTS { ?iri ex:role ?o }` |
    # | `30..40` | `?iri ex:age ?age . FILTER(?age >= 30 && ?age <= 40)` |
    # | `/^Al/` | `?iri foaf:name ?name . FILTER(REGEX(?name, "^Al"))` |
    # | `[a, b]` | `FILTER(?v IN (a, b))` |
    # | a record | its subject IRI |
    #
    # @return [PgRipple::Relation, PgRipple::Relation::WhereChain]
    def where(conditions = nil)
      return WhereChain.new(self) if conditions.nil?

      build { |query, scope| apply_where(query, scope, conditions) }
    end

    # `#limit` and `#offset` stay on this side of the fence.
    #
    # They are the two `ActiveRecord::Relation` methods this class does *not*
    # forward, because forwarding them would settle the SQL before anything
    # could decide whether the bound belongs in the SPARQL — and it usually
    # does. See {#sparql_for_scope}. Everything else about them is ordinary:
    # the value still ends up on the relation.
    #
    # @param value [Integer]
    # @return [PgRipple::Relation]
    def limit(value)
      build { |_query, scope| scope.limit(value) }
    end

    # @param value [Integer]
    # @return [PgRipple::Relation]
    def offset(value)
      build { |_query, scope| scope.offset(value) }
    end

    # Scopes the traversal to a named graph.
    #
    # @param graph_name [String, RDF::URI]
    # @return [PgRipple::Relation]
    def in_graph(graph_name)
      self.class.new(model, scope: @scope, query: query.with_graph_name(graph_name))
    end

    # Traverses a property path from a known subject.
    #
    # `Person.graph.via(+ex.manages, from: alice)` is the model-side spelling of
    # what `graph_has_many :reports, path: +ex.manages` gives a record.
    #
    # @param path [PgRipple::Path, RDF::URI]
    # @param from [Object] a record, an `RDF::URI` or an IRI string
    # @return [PgRipple::Relation]
    def via(path, from:)
      build { |query, _scope| query.traverse(from: self.class.subject_term(from), path: PgRipple::Path.coerce(path)) }
    end

    # The SPARQL the lateral will actually run, `LIMIT` and all.
    #
    # Deliberately not `query.to_s`: whether the bound is pushed into the
    # SPARQL is the most consequential decision this class makes, and a
    # `#to_sparql` that hid it would be inspecting something other than what
    # runs.
    #
    # @return [String]
    def to_sparql
      sparql_for_scope
    end

    # @return [String] the SQL this compiles to, traversal and all
    def to_sql
      scope.to_sql
    end

    # pg_ripple's own plan for the traversal.
    #
    # `pg_ripple.explain_sparql()`, not PostgreSQL's `EXPLAIN` — the interesting
    # plan is the one inside the extension, since from SQL's point of view the
    # whole traversal is a single function scan. {#explain_sql} is the other
    # one.
    #
    # @param analyze [Boolean]
    # @return [String, Hash]
    def explain(analyze: false)
      repository.explain_sparql(to_sparql, analyze: analyze)
    end

    # @return [String] PostgreSQL's plan for the SQL around the traversal
    def explain_sql(...)
      scope.explain(...)
    end

    # Streams the traversal in batches, bounded on the graph side.
    #
    # ActiveRecord's own `find_each` would batch on the *table*: an `ORDER BY
    # id` and an `id > ?` predicate per batch, each of which re-runs the entire
    # traversal and throws all but a page of it away — `pg_ripple.sparql()`
    # materialises every solution before returning its first row. So the paging
    # happens in SPARQL, through `pg_ripple.sparql_cursor()`, whose page-at-a-
    # time portal is what bounds peak memory (`docs/probe-lateral-join.md` §f).
    #
    # An `ORDER BY ?iri` goes into the query, because a SPARQL query without one
    # has no defined solution order and paging an unordered result can visit a
    # subject twice and another never.
    #
    # The rows for each page are fetched by `iri IN (…)` rather than by another
    # lateral, which keeps every SQL condition on the relation working and makes
    # a page's solution count exactly knowable — a lateral's SQL predicates can
    # drop rows, so a short page would be indistinguishable from the last one.
    #
    # @param batch_size [Integer]
    # @yieldparam [ActiveRecord::Base]
    # @return [Enumerator, void]
    def find_each(batch_size: 1000, &block)
      return enum_for(:find_each, batch_size: batch_size) unless block

      find_in_batches(batch_size: batch_size) { |records| records.each(&block) }
    end

    # @param batch_size [Integer]
    # @yieldparam [Array<ActiveRecord::Base>]
    # @return [Enumerator, void]
    def find_in_batches(batch_size: 1000)
      return enum_for(:find_in_batches, batch_size: batch_size) unless block_given?

      offset = 0
      column = self.class.iri_column(model)

      loop do
        page = query.dup.order_by_subject.slice(limit: batch_size, offset: offset)
        iris = repository.sparql_cursor(page.to_s).filter_map { |solution| solution[Query::SUBJECT.to_sym]&.to_s }

        break if iris.empty?

        records = @scope.where(column => iris).to_a
        yield records unless records.empty?

        break if iris.size < batch_size

        offset += batch_size
      end
    end

    # The `ActiveRecord::Relation` this builds.
    #
    # Everything {#method_missing} forwards goes here first, so asking for it
    # explicitly is only needed when a name would otherwise be caught by this
    # class — `where`, mainly.
    #
    # @return [ActiveRecord::Relation]
    def scope
      @relation ||= self.class.attach(sql_scope, sparql_for_scope)
    end
    alias_method :to_relation, :scope

    # @return [String]
    def inspect
      "#<#{self.class} #{model.name} #{to_sparql.inspect}>"
    end

    # ActiveRecord's own query builders, which keep this object alive.
    #
    # `#order` and `#includes` return another {PgRipple::Relation} rather than
    # dissolving into an `ActiveRecord::Relation`, because both of them change
    # the answer to "may the `LIMIT` go into the SPARQL?" — and a chain that had
    # already dissolved could not be asked. Everything terminal (`#to_a`,
    # `#count`, `#pluck`, `#each`, Kaminari's `#page`) builds the relation and
    # goes through it, so the proxy is invisible unless you look.
    # Computed on first use rather than in the class body: naming
    # `ActiveRecord::QueryMethods` while `active_record/relation` is itself
    # mid-load walks straight into its autoload cycle.
    #
    # @return [Set<Symbol>]
    def self.relation_builders
      @relation_builders ||= (
        ActiveRecord::QueryMethods.public_instance_methods(false) +
        ActiveRecord::SpawnMethods.public_instance_methods(false) +
        # Not ActiveRecord's, but exactly one of these: it returns a relation
        # and changes nothing about the traversal, so `Person.graph.where(role:
        # "manager").graph_includes(:reports)` has to stay a
        # {PgRipple::Relation} rather than dissolving into an
        # `ActiveRecord::Relation` that can no longer decide whether the
        # `LIMIT` may go into the SPARQL.
        %i[graph_includes]
      ).to_set - %i[where limit offset arel structurally_compatible?]
    end

    # Anything this class does not define is ActiveRecord's.
    def method_missing(name, *args, **kwargs, &block)
      if self.class.relation_builders.include?(name)
        built = @scope.public_send(name, *args, **kwargs, &block)
        return build { built } if built.is_a?(ActiveRecord::Relation)

        return built
      end

      return super unless scope.respond_to?(name)

      scope.public_send(name, *args, **kwargs, &block)
    end

    def respond_to_missing?(name, include_private = false)
      scope.respond_to?(name, include_private) || super
    end

    # @api private
    def self.subject_term(from)
      case from
      when RDF::Term then from
      when String then RDF::URI(from)
      else
        return from.rdf_subject if from.respond_to?(:rdf_subject)

        raise ArgumentError, "#{from.inspect} has no subject IRI; pass a record, an RDF::URI or a String"
      end
    end

    private

    def default_query
      query = Query.new(graph_name: PgRipple.configuration.default_graph)
      Array(model.graph_schema&.types).each { |type| query.type(type) }
      query
    end

    def build
      query = @query.dup
      scope = @scope
      result = yield(query, scope)
      scope = result if result.is_a?(ActiveRecord::Relation)

      self.class.new(model, scope: scope, query: query)
    end

    def apply_where(query, scope, conditions)
      conditions.each do |name, value|
        property = graph_property(name)

        if property.nil?
          scope = scope.where(name => value)
        else
          condition(query, property, name, value)
        end
      end

      scope
    end

    def apply_not(query, scope, conditions)
      conditions.each do |name, value|
        property = graph_property(name)

        if property.nil?
          scope = scope.where.not(name => value)
          next
        end

        path = PgRipple::Path.coerce(property.predicate)

        if value.nil?
          # `where.not(role: nil)` is "has a role at all".
          query.bind(path, name)
        else
          Array(value).each { |v| query.not_exists(path, term(property, v)) }
        end
      end

      scope
    end

    def condition(query, property, name, value)
      path = PgRipple::Path.coerce(property.predicate)

      case value
      when nil
        query.not_exists(path)
      when Range
        range_filter(query, property, path, name, value)
      when Regexp
        regexp_filter(query, path, name, value)
      when Array
        variable = query.bind(path, name)
        terms = value.map { |v| PgRipple::Term.sparql(term(property, v)) }
        query.filter("?#{variable} IN (#{terms.join(", ")})")
      else
        query.equal(path, term(property, value))
      end
    end

    def range_filter(query, property, path, name, range)
      variable = query.bind(path, name)
      tests = []

      unless range.begin.nil?
        tests << "?#{variable} >= #{PgRipple::Term.sparql(term(property, range.begin))}"
      end

      unless range.end.nil?
        operator = range.exclude_end? ? "<" : "<="
        tests << "?#{variable} #{operator} #{PgRipple::Term.sparql(term(property, range.end))}"
      end

      query.filter(tests.join(" && ")) unless tests.empty?
    end

    # `REGEX(?name, "^Al")`, with the pattern as an escaped SPARQL literal
    # rather than as text spliced into the query.
    #
    # Only the flags SPARQL has are passed through — `i` and `m` (`s` in Ruby is
    # an encoding option, not a flag, and `x` has no XPath equivalent).
    def regexp_filter(query, path, name, regexp)
      variable = query.bind(path, name)
      pattern = PgRipple::Term.sparql(RDF::Literal(regexp.source))

      flags = +""
      flags << "i" if regexp.options.anybits?(Regexp::IGNORECASE)
      flags << "m" if regexp.options.anybits?(Regexp::MULTILINE)

      arguments = ["?#{variable}", pattern]
      arguments << PgRipple::Term.sparql(RDF::Literal(flags)) unless flags.empty?

      query.filter("REGEX(#{arguments.join(", ")})")
    end

    def graph_property(name)
      schema = model.graph_schema
      property = schema && schema[name]
      return property if property

      unless model.column_names.include?(name.to_s)
        raise PgRipple::UnknownProperty.new(
          "#{model.name} has no graph property or column #{name.inspect}; declared graph properties: " \
          "#{Array(schema&.names).map(&:inspect).join(", ")}",
          name.to_sym
        )
      end

      nil
    end

    # A Ruby value as the RDF term to compare against.
    #
    # Through the property's own `cast:` first, so a comparison is written in
    # the same terms the write was — otherwise `where(email: "alice@x")` would
    # look for a plain literal where a `mailto:` IRI was stored.
    def term(property, value)
      return value if value.is_a?(RDF::Term)
      return value.rdf_subject if value.respond_to?(:rdf_subject)

      coerced = property ? property.coerce(value) : value
      coerced.is_a?(RDF::Term) ? coerced : RDF::Literal(coerced)
    end

    def repository
      PgRipple.repository(graph_name: query.graph_name)
    end

    # The SPARQL the lateral runs, with `LIMIT`/`OFFSET` pushed down when that
    # cannot change the answer.
    #
    # It usually cannot be pushed down. `pg_ripple.sparql()` builds every
    # solution before PostgreSQL sees the first one, so an outer `LIMIT 20` is
    # pure client-side truncation of work already done — 40× slower than the
    # same query with `LIMIT 20` inside it on a 25 921-solution traversal. But
    # anything downstream of the lateral that can *drop* a row makes the
    # pushdown wrong rather than slow: `alice.network.where(active: true)
    # .limit(20)` would truncate the traversal to 20 solutions and then filter
    # those, returning fewer than 20 rows.
    #
    # So it is pushed down only when the SQL around the join can drop nothing —
    # no `WHERE`, no `ORDER BY`, no other join, no grouping, no eager load — and
    # when the traversal is closed over this model's own subjects, which is what
    # `Model.graph`'s `?iri a <Type>` gives and a bare path traversal does not.
    # The residue: a subject of the right type whose row is missing still
    # shortens the page. {PgRipple::Node} maintains that invariant — it mints a
    # subject on create and erases it on destroy — so the case is a row deleted
    # behind the gem's back, and it is why an association's `#limit` is never
    # pushed down.
    #
    # Two things follow from pushing it down, and both were bugs before they
    # were rules:
    #
    # - **The `OFFSET` has to come *off* the SQL.** `LIMIT` is idempotent — the
    #   lateral already returns at most 20 rows, so an outer `LIMIT 20` drops
    #   nothing — but an outer `OFFSET 20` skips 20 of the 20 rows the SPARQL
    #   already skipped to, and the page comes back empty. Measured on 60
    #   records: `limit(20)` gave 20 and `limit(20).offset(20)` gave **0**. So
    #   {#sql_scope} strips it. The `LIMIT` is left on as a cheap backstop
    #   against a duplicated `iri`.
    # - **The query has to be ordered.** SPARQL defines no solution order
    #   without an `ORDER BY`, so `LIMIT`/`OFFSET` over an unordered result can
    #   return a subject on two pages and another on none. The bound is only
    #   pushed down when the caller asked for no SQL ordering of their own, so
    #   `ORDER BY ?iri` is free to be the order, and it is the same reason
    #   {#find_in_batches} has always asked for it.
    def sparql_for_scope
      return query.to_s unless push_down_slice?

      query.dup.order_by_subject.slice(limit: @scope.limit_value, offset: @scope.offset_value).to_s
    end

    # The SQL half, with anything the SPARQL now does taken off it.
    def sql_scope
      return @scope unless push_down_slice?

      @scope.offset(nil)
    end

    def push_down_slice?
      return false if @scope.limit_value.nil? && @scope.offset_value.nil?
      return false if query.empty? || !type_closed?

      @scope.where_clause.empty? &&
        @scope.order_values.empty? &&
        @scope.joins_values.empty? &&
        @scope.left_outer_joins_values.empty? &&
        @scope.includes_values.empty? &&
        @scope.group_values.empty? &&
        @scope.having_clause.empty? &&
        !@scope.distinct_value
    end

    # Whether the traversal only ever reaches subjects this model owns.
    def type_closed?
      types = Array(model.graph_schema&.types)
      return false if types.empty?

      sparql = query.to_s
      types.any? { |type| sparql.include?("a #{PgRipple::Term.sparql(RDF::URI.intern(type))} .") }
    end
  end
end

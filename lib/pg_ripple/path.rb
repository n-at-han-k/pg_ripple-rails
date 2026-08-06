# frozen_string_literal: true

require "rdf"
require "string_builder"

require "pg_ripple/prefixes"
require "pg_ripple/handlers/sparql_path"

module PgRipple
  # Raised by {Path#to_term} when the path is not a single predicate.
  #
  # `TypeError` rather than `ArgumentError`: the caller asked a path to be an
  # `RDF::URI` and it is not one. Every caller of `#to_term` — the association
  # builder deciding whether it can write `INSERT DATA`, the repository
  # deciding whether it can use `find_triples` — is asking a type question.
  class NotAPredicate < TypeError; end
end

module PgRipple
  # A SPARQL 1.1 property path, built with Ruby operators.
  #
  #     foaf.knows                    # => foaf:knows
  #     foaf.knows / ex.worksAt       # => foaf:knows/ex:worksAt
  #     foaf.knows | ex.colleague     # => foaf:knows|ex:colleague
  #     +foaf.knows                   # => foaf:knows+
  #     foaf.knows.any                # => foaf:knows*
  #     foaf.knows.opt                # => foaf:knows?
  #     ~ex.manages                   # => ^ex:manages
  #     !rdf.type                     # => !(rdf:type)
  #
  # ## A path is a value
  #
  # Every combinator returns a *new* frozen path; nothing mutates in place. That
  # is the difference between this and a bare `StringBuilder`, whose chain
  # methods `tap` and mutate, and it is what makes the README's
  #
  #     path = ~ex.worksAt / ex.worksAt
  #     path.inverse
  #     path.to_s   # still "^ex:worksAt/ex:worksAt"
  #
  # true. A mutating builder would also make a vocabulary single-use: `foaf.knows`
  # would leave `knows` in `foaf`'s buffer and the next `foaf.name` would render
  # as `foaf:knows foaf:name`.
  #
  # ## Precedence
  #
  # Ruby's precedence and SPARQL's agree on the binary operators — `/` binds
  # tighter than `|` in both — so `a / b | c / d` needs no parentheses in either
  # language and renders as `a/b|c/d`. The unary operators are where it gets
  # interesting: Ruby binds `~` and unary `+` tighter than any binary operator,
  # so
  #
  #     ~ex.worksAt / ex.worksAt
  #
  # parses as `(~ex.worksAt) / ex.worksAt` and must render `^ex:worksAt/ex:worksAt`,
  # *not* `^(ex:worksAt/ex:worksAt)` — which is a different path, and one that
  # would silently return the wrong colleagues rather than fail.
  #
  # Parenthesisation is decided here, at build time, not in the handler: this is
  # the only place both operands and their precedences are known. Each path
  # carries a {#precedence}, and an operand is wrapped only when its own
  # precedence is lower than the operator needs. The handler then renders a flat
  # token stream that is already correct.
  #
  # ## What it uses from StringBuilder, and what it does not
  #
  # It is a `StringBuilder` subclass and uses two things from it: the token
  # buffer, and the `concat_handler` seam that turns tokens into text. The
  # README's sketch spells the second one as a class macro —
  #
  #     class PgRipple::Path < StringBuilder
  #       handler PgRipple::Handlers::SparqlPath
  #     end
  #
  # — but string_builder 1.2.4 has no `handler` macro. It offers
  # `attr_accessor :concat_handler` and an `initialize(&custom_concat)` block,
  # both per-instance. {.handler} below is our own one-line class macro over
  # that accessor, so the README's spelling works on a class we own. See
  # `docs/spec-corrections.md` §8.
  #
  # Two further deliberate divergences from the gem:
  #
  # * **`method_missing` is disabled.** StringBuilder records *any* unknown
  #   method as a token. On a path that turns `foaf.knows.opts` — a typo — into a
  #   silent extra token rather than a `NoMethodError`, and the query would run
  #   and return the wrong rows. Tokens here come only from the operators.
  # * **`/` is a real operator.** The gem's `/` lives on `InnerStringBuilder`
  #   and only inside a `wrap { }` block, via `OPERATOR_MAP`. A path is built in
  #   a class body, not a block, so `#/` is defined directly.
  class Path < StringBuilder
    # Precedence levels, loosest first. The numbers are only ever compared, and
    # they are SPARQL's own grammar productions rather than a convenience
    # ordering:
    #
    #   PathAlternative  ::= PathSequence ('|' PathSequence)*        ALT
    #   PathSequence     ::= PathEltOrInverse ('/' PathEltOrInverse)* SEQ
    #   PathEltOrInverse ::= '^'? PathPrimary PathMod?               MOD
    #   PathPrimary      ::= iri | '!' PathNegatedPropertySet | '(' Path ')'  ATOM
    #
    # {MOD} being *below* {ATOM} is the part that is easy to get wrong: a
    # `PathElt` carries at most one `PathMod`, so `a+?` is a syntax error and
    # `(a+)?` is what was meant. Only a `PathPrimary` may take a modifier.
    ALT = 0   # a|b
    SEQ = 1   # a/b
    MOD = 2   # ^a, a+, a*, a?
    ATOM = 3  # a, !(a), (a|b)

    # The token name a leaf carries its RDF term under.
    TERM = Handlers::SparqlPath::TERM

    class << self
      # Sets (or reads) the concat handler for this class and its subclasses.
      #
      # @param handler [#call, nil]
      # @return [#call]
      def handler(handler = nil)
        @handler = handler unless handler.nil?
        return @handler if defined?(@handler) && @handler

        superclass.respond_to?(:handler) ? superclass.handler : nil
      end

      # A path of exactly one predicate.
      #
      # @param term [RDF::Term] normally an `RDF::URI`
      # @return [PgRipple::Path]
      def term(term)
        unless term.is_a?(RDF::Term)
          raise ArgumentError, "#{term.inspect} is not an RDF::Term; a path leaf is a term, " \
            "not a string — build it with RDF::URI() or a vocabulary"
        end

        new([[TERM, [term]]], precedence: ATOM)
      end

      # A vocabulary front end, so predicates read as `foaf.knows`.
      #
      # @param namespace [RDF::Vocabulary, RDF::URI, String] the vocabulary, or
      #   its namespace IRI
      # @param prefix [String, Symbol, nil] registers the prefix with
      #   {PgRipple::Prefixes} so paths over this namespace render abbreviated.
      #   Omitted for an `RDF::Vocabulary`, its own `__prefix__` is used.
      # @return [PgRipple::Path::Vocabulary]
      def vocabulary(namespace, prefix: nil)
        Vocabulary.new(namespace, prefix: prefix)
      end

      # Accepts a path, an `RDF::Term` or another path-like thing on the
      # right-hand side of an operator.
      #
      # A String is refused on purpose: `"foaf:knows"` and
      # `"http://xmlns.com/foaf/0.1/knows"` are both plausible readings of a
      # bare string and guessing between them is how a path silently addresses
      # the wrong predicate.
      #
      # @param other [PgRipple::Path, RDF::Term]
      # @return [PgRipple::Path]
      def coerce(other)
        case other
        when Path then other
        when RDF::Term then term(other)
        else
          raise TypeError, "#{other.inspect} is not a PgRipple::Path or an RDF::Term"
        end
      end
    end

    handler Handlers::SparqlPath

    # How tightly this path binds. One of {ALT}, {SEQ}, {ATOM}.
    attr_reader :precedence

    # @param tokens [Array] token stream, already in output order
    # @param precedence [Integer]
    # @api private
    def initialize(tokens = [], precedence: ATOM)
      super()
      self.concat_handler = self.class.handler
      tokens.each { |token| @buffer << token }
      @precedence = precedence
      @buffer.freeze
      freeze
    end

    # @return [Array] this path's tokens, in output order
    def tokens
      @buffer
    end

    # Sequence: `a/b`.
    #
    # @param other [PgRipple::Path, RDF::Term]
    # @return [PgRipple::Path]
    def /(other)
      other = self.class.coerce(other)

      # Both operands are allowed to be sequences and are flattened rather than
      # parenthesised: `/` is associative, so `a/b/c`, `(a/b)/c` and `a/(b/c)`
      # denote the same relation and the flat form is the one a human reading
      # the emitted SPARQL expects. Only an alternative is grouped.
      build(tokens_at_least(SEQ) + [:slash] + other.tokens_at_least(SEQ), SEQ)
    end

    # Alternative: `a|b`. Nothing needs parenthesising — `|` is the loosest
    # operator in the grammar and is associative.
    #
    # @param other [PgRipple::Path, RDF::Term]
    # @return [PgRipple::Path]
    def |(other)
      other = self.class.coerce(other)

      build(tokens.to_a + [:pipe] + other.tokens.to_a, ALT)
    end

    # One or more: `a+`. Spelled `+path` in Ruby.
    #
    # @return [PgRipple::Path]
    def +@
      modified(:plus)
    end
    alias_method :one_or_more, :+@

    # Zero or more: `a*`.
    #
    # Named `any` rather than `*`, because Ruby's binary `*` would need a
    # right-hand operand and its unary `*` is splat, which cannot be overridden.
    #
    # @return [PgRipple::Path]
    def any
      modified(:star)
    end
    alias_method :zero_or_more, :any

    # Optional: `a?`. Named `opt` for the same reason `any` is not `*`.
    #
    # @return [PgRipple::Path]
    def opt
      modified(:question)
    end
    alias_method :optional, :opt

    # Inverse: `^a`. Spelled `~path` in Ruby.
    #
    # A modified atom needs no parentheses: SPARQL's `PathEltOrInverse` is
    # `'^'? PathPrimary PathMod?`, so `^a+` already means `^(a+)`, and `^(a+)`
    # and `(^a)+` denote the same relation. A sequence or an alternative does
    # need them.
    #
    # An *inverse* needs them too, and that is the one case the precedence
    # table alone gets wrong. `PathEltOrInverse` admits at most one `'^'`, so
    # `^^a` is a syntax error rather than a double inverse — but an inverse
    # already sits at {MOD}, so `tokens_at_least(MOD)` adds nothing and the
    # carets stack. `~~path` and `path.inverse.inverse` are both reachable from
    # the README's own "Property paths" section, so this is checked here:
    # `^(^a)`, which parses and denotes the identity round trip.
    #
    # @return [PgRipple::Path]
    def ~
      build([:caret] + tokens_at_least(inverse? ? ATOM : MOD), MOD)
    end
    alias_method :inverse, :~

    # Negated property set: `!(a)`, `!(a|^b)`. Spelled `!path` in Ruby.
    #
    # The parentheses are unconditional, matching the README, and legal for the
    # single-predicate case too.
    #
    # SPARQL restricts the contents to IRIs and inverse IRIs joined by `|` —
    # `!(a/b)` and `!(a+)` are not paths at all. That is checked here and
    # raises, rather than emitting SPARQL the server will reject with a parse
    # error naming a query the caller never wrote.
    #
    # @return [PgRipple::Path]
    # @raise [ArgumentError] if the path is not a set of predicates and inverse
    #   predicates
    def !
      unless negatable?
        raise ArgumentError, "a negated property set may only contain predicates and " \
          "inverse predicates joined by `|`; #{to_s.inspect} is not one"
      end

      build([:bang, :group_open] + tokens.to_a + [:group_close], ATOM)
    end
    alias_method :negated, :!

    # @return [Boolean] true when the path is an inverse — `^a`, `^(a/b)`
    def inverse?
      tokens.first == :caret
    end

    # @return [Boolean] true when the path is exactly one predicate
    def single_predicate?
      tokens.length == 1 && tokens.first.is_a?(Array) && tokens.first.first == TERM
    end

    # The path as an `RDF::URI`, when it is a single predicate.
    #
    # This is the single seam back into RDF.rb: a caller with a term can write
    # a triple, use `find_triples`, or hand the predicate to ActiveTriples. A
    # caller with a path can only ask SPARQL.
    #
    # The README sketches this as `RDF::URI(to_s)`, which is why it is spelled
    # out here: `RDF::URI("foaf:knows+")` is a perfectly constructible relative
    # `RDF::URI` that means nothing, and the failure would surface later as a
    # triple written against a predicate no query looks for. It raises instead.
    #
    # @return [RDF::URI]
    # @raise [PgRipple::NotAPredicate] when the path is more than one predicate
    def to_term
      unless single_predicate?
        raise NotAPredicate, "#{to_s.inspect} is a property path, not a single predicate; " \
          "only a single predicate has an RDF::URI"
      end

      tokens.first.last.first
    end

    # Every RDF term this path names, in order.
    #
    # @return [Array<RDF::Term>]
    def terms
      tokens.filter_map { |token| token.last.first if token.is_a?(Array) && token.first == TERM }
    end

    # The namespace prefixes {#to_s} actually used.
    #
    # The query builder needs this: whether a term renders as `foaf:knows` or as
    # `<http://xmlns.com/foaf/0.1/knows>` depends on what is registered in this
    # process, so a query cannot assume a fixed `PREFIX` header. Ask the path.
    #
    # @return [Array<String>] sorted, unique
    # @see PgRipple::Prefixes.declarations
    def prefixes
      terms.filter_map { |term| Prefixes.prefix_for(term) if term.is_a?(RDF::URI) }.uniq.sort
    end

    # @return [String] the SPARQL `PREFIX` declarations this path needs
    def prefix_declarations
      Prefixes.declarations(prefixes)
    end

    # @return [Boolean] paths are equal when they render identically
    def ==(other)
      other.is_a?(Path) && to_s == other.to_s
    end
    alias_method :eql?, :==

    def hash
      [self.class, to_s].hash
    end

    def inspect
      "#<#{self.class} #{to_s.inspect}>"
    end

    # @api private
    # @return [Array] tokens, parenthesised if this path binds looser than the
    #   given level
    def tokens_at_least(level)
      return tokens.to_a if precedence >= level

      [:group_open] + tokens.to_a + [:group_close]
    end

    private

    # StringBuilder turns every unknown method into a token. On a path that
    # would make a typo a silently wrong query, so it is switched back off.
    def method_missing(name, *, **, &)
      raise NoMethodError, "undefined method #{name} for #{inspect}"
    end

    def respond_to_missing?(_name, _include_private = false)
      false
    end

    def build(tokens, precedence)
      self.class.new(tokens, precedence: precedence)
    end

    def modified(operator)
      build(tokens_at_least(ATOM) + [operator], MOD)
    end

    # `!` accepts only predicates, inverse predicates and `|` between them.
    def negatable?
      tokens.all? do |token|
        token == :caret || token == :pipe ||
          (token.is_a?(Array) && token.first == TERM)
      end
    end

    # A namespace, addressed by method name.
    #
    #     ex = PgRipple::Path.vocabulary("https://example.com/ns#", prefix: "ex")
    #     ex.worksAt          # => #<PgRipple::Path "ex:worksAt">
    #     ex[:worksAt]        # same
    #
    # Almost every method inherited from `Object` is undefined here, because
    # each one is a predicate name that would otherwise not reach
    # `method_missing`: `ex.class`, `ex.hash`, `ex.display`, `ex.method` and
    # `ex.then` are all plausible predicates. Use `ex[:name]` for anything this
    # still swallows.
    class Vocabulary
      KEEP = %i[__send__ __id__ object_id equal? freeze frozen? instance_variable_get].freeze
      (instance_methods - KEEP).each { |method| undef_method(method) }

      # @param namespace [RDF::Vocabulary, RDF::URI, String]
      # @param prefix [String, Symbol, nil]
      def initialize(namespace, prefix: nil)
        @namespace = namespace
        @base = (namespace.respond_to?(:to_uri) ? namespace.to_uri : RDF::URI(namespace)).to_s

        prefix ||= namespace.__prefix__ if namespace.respond_to?(:__prefix__)
        Prefixes.register(prefix, @base) if prefix

        freeze
      end

      # @param name [String, Symbol]
      # @return [PgRipple::Path]
      def [](name)
        Path.term(RDF::URI(@base + name.to_s))
      end

      def inspect
        "#<#{Path::Vocabulary} #{@base.inspect}>"
      end

      private

      def method_missing(name, *args, **kwargs, &blk)
        unless args.empty? && kwargs.empty? && blk.nil?
          ::Kernel.raise ::ArgumentError,
            "#{name} takes no arguments; a vocabulary term is just a name"
        end

        self[name]
      end

      def respond_to_missing?(_name, _include_private = false) = true
    end
  end
end

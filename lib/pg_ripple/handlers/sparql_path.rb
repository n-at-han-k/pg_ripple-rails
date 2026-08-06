# frozen_string_literal: true

require "rdf"

require "pg_ripple/prefixes"
require "pg_ripple/term"

module PgRipple
  # StringBuilder concat handlers: one per output language.
  #
  # A handler is anything answering `.call(buffer)` and returning a String —
  # the contract `StringBuilder::Concat::Default` already implements. It never
  # decides *what* is in the chain, only how the tokens become text.
  module Handlers
    # Renders a {PgRipple::Path} token buffer as a SPARQL 1.1 property path.
    #
    # The buffer is already in output order and already carries its parentheses:
    # precedence is settled where the path is *built*, because that is the only
    # place both operands are known. So this class is a pure `map`/`join` with
    # no state, which is what makes it cheap to test against the README table
    # one row at a time.
    #
    # It is not `Concat::Default` with a different separator. `Default` joins
    # with a space and renders arguments with `#inspect`; a property path has no
    # spaces and its leaves are RDF terms, which must go through
    # `RDF::Literal#to_base` / `RDF::URI#to_base` rather than `#to_s` so that
    # escaping, datatypes and language tags come from ruby-rdf's implementation
    # of the W3C grammar and not from this gem.
    class SparqlPath
      # Every structural token the path builder can emit. A token outside this
      # set is a bug in {PgRipple::Path}, not user input, so it raises.
      OPERATORS = {
        slash: "/",
        pipe: "|",
        plus: "+",
        star: "*",
        question: "?",
        caret: "^",
        bang: "!",
        group_open: "(",
        group_close: ")"
      }.freeze

      # The token name under which a leaf carries its RDF term. StringBuilder's
      # buffer entries are `[name, args]` pairs, so a leaf is
      # `["term", [RDF::URI(…)]]` — the term travels as an *object*, never as a
      # string, and is only serialised here.
      TERM = "term"

      # Characters SPARQL 1.1's `IRIREF` production excludes:
      #
      #     IRIREF ::= '<' ([^<>"{}|^`\]-[#x00-#x20])* '>'
      #
      # Note what is *not* there: SPARQL, unlike N-Triples, has no `UCHAR`
      # escape inside an IRIREF. So `RDF::URI#to_base` — which is N-Triples and
      # does escape, emitting `>` for `>` — produces something SPARQL
      # cannot parse for exactly these characters. There is no correct
      # rendering: percent-encoding would silently change the IRI, and RDF
      # compares IRIs by string.
      #
      # Defined once, in {PgRipple::Term}, because the update writer needs the
      # same rule and a second copy of a regex is a second chance to get it
      # wrong.
      FORBIDDEN_IN_IRIREF = PgRipple::Term::FORBIDDEN_IN_IRIREF

      # @param buffer [Enumerable] a {PgRipple::Path}, or any enumerable of its
      #   tokens
      # @return [String]
      def self.call(buffer) = new(buffer).concat

      attr_reader :buffer

      def initialize(buffer) = @buffer = buffer

      # @return [String] the SPARQL property path
      def concat
        buffer.map { |entry| render(entry) }.join
      end

      private

      def render(entry)
        return operator(entry) if entry.is_a?(Symbol)

        name, args = entry
        unless name == TERM
          raise ArgumentError, "#{self.class} cannot render the token #{name.inspect}"
        end

        serialize(args.first)
      end

      def operator(symbol)
        OPERATORS.fetch(symbol) do
          raise ArgumentError, "#{self.class} has no operator for #{symbol.inspect}"
        end
      end

      # `RDF::Literal` is checked before `RDF::URI` because neither is a
      # subclass of the other and a datatyped literal must not lose its `^^`.
      # A property path cannot legally contain a literal, but the leaf
      # serialiser is the seam every handler in this namespace shares, and one
      # that quietly dropped a datatype would be wrong in the Turtle handler
      # too.
      def serialize(term)
        case term
        when RDF::Literal then term.to_base
        when RDF::URI then Prefixes.pname(term) || iriref(term)
        when RDF::Term then term.to_base
        else
          raise ArgumentError, "#{term.inspect} is not an RDF::Term"
        end
      end

      def iriref(uri)
        offender = FORBIDDEN_IN_IRIREF.match(uri.to_s)
        if offender
          raise ArgumentError, "<#{uri}> cannot be written in SPARQL: the character " \
            "#{offender[0].inspect} is excluded from SPARQL's IRIREF production and, unlike " \
            "N-Triples, SPARQL has no escape for it"
        end

        uri.to_base
      end
    end
  end
end

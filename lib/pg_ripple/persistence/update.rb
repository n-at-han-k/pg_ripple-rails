# frozen_string_literal: true

require "rdf"

require "pg_ripple/term"

module PgRipple
  module Persistence
    # A SPARQL 1.1 Update request, built from RDF terms rather than from text.
    #
    # Every value that reaches the wire goes through {PgRipple::Term.sparql},
    # which is ruby-rdf's N-Triples writer plus SPARQL's narrower `IRIREF`
    # rule. Nothing is interpolated: a literal holding `"`, `}`, a newline or a
    # `$` is escaped by the same code that reads it back, so there is one
    # encoding to be right about rather than two.
    #
    # Operations are joined with `;`, which pg_ripple 0.128.0 executes as one
    # request in the caller's transaction — measured, not assumed: a
    # `DELETE DATA … ; INSERT DATA …` pair returned `2` from
    # `pg_ripple.sparql_update()` and left exactly the replaced triple behind.
    #
    # @example
    #   update = PgRipple::Persistence::Update.new
    #   update.delete_data([[alice, EX.role, "engineer"]])
    #   update.insert_data([[alice, EX.role, "manager"]])
    #   update.to_s
    #   # => DELETE DATA { … } ;
    #   #    INSERT DATA { … }
    #
    # @api private
    class Update
      # Raised when a statement cannot appear in the operation it was given to.
      class Unwritable < ArgumentError; end

      # @return [RDF::URI, nil] the named graph every operation is wrapped in
      attr_reader :graph_name

      # @param graph_name [RDF::URI, String, nil] nil for the default graph
      def initialize(graph_name: nil)
        @graph_name = graph_name.nil? ? nil : RDF::URI(PgRipple::Term.graph_argument(graph_name))
        @operations = []
      end

      # Retracts exactly these triples.
      #
      # @param statements [Enumerable<RDF::Statement>]
      # @return [self]
      # @raise [Unwritable] on a blank node — SPARQL 1.1 forbids one in
      #   `DELETE DATA`, because a query's `_:b` is a fresh variable and could
      #   not name the node the caller meant
      def delete_data(statements)
        statements = normalize(statements)
        return self if statements.empty?

        statements.each { |statement| reject_blank_nodes!(statement, "DELETE DATA") }
        @operations << "DELETE DATA #{block(statements)}"
        self
      end

      # Asserts exactly these triples.
      #
      # @param statements [Enumerable<RDF::Statement>]
      # @return [self]
      def insert_data(statements)
        statements = normalize(statements)
        return self if statements.empty?

        @operations << "INSERT DATA #{block(statements)}"
        self
      end

      # Retracts every triple matching a pattern.
      #
      # The whole-subject rewrite the README names as the anti-pattern is
      # `DELETE WHERE { <s> ?p ?o }`, and it is here for the two cases where it
      # is the right answer rather than a shortcut: erasing a destroyed
      # subject, and `dependent: :nullify_references` erasing the edges that
      # point *at* it, which nothing can enumerate cheaply from this side.
      #
      # @param subject [RDF::Term, nil] nil for a variable
      # @param predicate [RDF::Term, nil]
      # @param object [RDF::Term, nil]
      # @return [self]
      def delete_where(subject: nil, predicate: nil, object: nil)
        terms = {s: subject, p: predicate, o: object}.map do |name, term|
          if term.nil?
            "?#{name}"
          else
            reject_blank_node!(term, "DELETE WHERE")
            PgRipple::Term.sparql(term)
          end
        end

        @operations << "DELETE WHERE #{block_body("#{terms.join(" ")} .")}"
        self
      end

      # @return [Boolean] whether there is anything to send
      def empty?
        @operations.empty?
      end

      # @return [String] the SPARQL Update request
      def to_s
        @operations.join(" ;\n")
      end

      private

      def normalize(statements)
        Array(statements).map { |s| s.is_a?(RDF::Statement) ? s : RDF::Statement.from(s) }
      end

      def block(statements)
        block_body(statements.map { |s| triple(s) }.join("\n"))
      end

      # The `{ … }` group, wrapped in a `GRAPH` block when this repository is
      # scoped to a named one. `INSERT DATA { GRAPH <g> { … } }` is the form
      # verified against 0.128.0; a bare group writes the default graph.
      def block_body(body)
        indented = body.gsub(/^/, "  ")

        return "{\n#{indented}\n}" if graph_name.nil?

        "{\n  GRAPH #{PgRipple::Term.sparql(graph_name)} {\n#{indented.gsub(/^/, "  ")}\n  }\n}"
      end

      def triple(statement)
        [statement.subject, statement.predicate, statement.object]
          .map { |term| PgRipple::Term.sparql(term) }
          .join(" ") + " ."
      end

      def reject_blank_nodes!(statement, operation)
        [statement.subject, statement.predicate, statement.object].each do |term|
          reject_blank_node!(term, operation)
        end
      end

      def reject_blank_node!(term, operation)
        return unless term.is_a?(RDF::Node)

        raise Unwritable, "#{operation} cannot name the blank node #{term.to_base}: " \
          "a blank node in a SPARQL update is a fresh node, not a reference to an existing one"
      end
    end
  end
end

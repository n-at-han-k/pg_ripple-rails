# frozen_string_literal: true

require "rdf"
require "rspec/expectations"

module PgRipple
  module RSpec
    module Matchers
      # Asserts that a triple is in the store.
      #
      #     expect(alice).to have_triple(EX.role, "manager")
      #     expect(PgRipple.repository).to have_triple([alice.rdf_subject, EX.role, "manager"])
      #
      # The subject can be anything answering `#rdf_subject` — a
      # {PgRipple::Node} record, an {ActiveTriples::RDFSource} — a bare
      # {RDF::Term}, or a repository, in which case the whole triple is given.
      #
      # It reads the *store*, not the record's in-memory graph, which is the
      # only way it can tell a save that wrote from a save that did not.
      class HaveTriple
        include ::RSpec::Matchers::Composable

        # @param pattern [Array] one, two or three terms
        def initialize(*pattern)
          @pattern = pattern.flatten(1)
        end

        def matches?(actual)
          @actual = actual
          @statement = statement_for(actual)

          repository.has_statement?(@statement)
        end

        def description = "have triple #{@pattern.map(&:inspect).join(" ")}"

        def failure_message
          "expected the store to hold #{@statement.to_base}, but it does not.\n" \
            "It holds, for that subject:\n#{subject_dump}"
        end

        def failure_message_when_negated
          "expected the store not to hold #{@statement.to_base}, but it does"
        end

        private

        def repository
          @actual.is_a?(RDF::Queryable) ? @actual : PgRipple.repository
        end

        def statement_for(actual)
          terms =
            if @pattern.size == 3
              @pattern
            else
              [subject_term(actual), *@pattern]
            end

          unless terms.size == 3
            raise ArgumentError,
              "have_triple needs a subject, a predicate and an object; got #{terms.size}"
          end

          RDF::Statement.from(terms)
        end

        def subject_term(actual)
          return actual.rdf_subject if actual.respond_to?(:rdf_subject)
          return actual if actual.is_a?(RDF::Resource)

          raise ArgumentError,
            "#{actual.inspect} has no rdf_subject; pass the whole triple instead"
        end

        def subject_dump
          statements = repository.query([@statement.subject, nil, nil]).to_a
          return "  (nothing)" if statements.empty?

          statements.map { |s| "  #{s.to_base}" }.join("\n")
        end
      end

      # @see PgRipple::RSpec::Matchers::HaveTriple
      def have_triple(*pattern)
        HaveTriple.new(*pattern)
      end
    end
  end
end

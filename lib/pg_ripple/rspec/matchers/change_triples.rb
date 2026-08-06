# frozen_string_literal: true

require "active_support/notifications"
require "rspec/expectations"

require "pg_ripple/persistence"

module PgRipple
  module RSpec
    module Matchers
      # Asserts what a block *wrote* to the graph.
      #
      #     expect { alice.update!(role: "manager") }.to change_triples(by: 1)
      #
      # **Not a before/after count.** The whole-object rewrite the README names
      # as the anti-pattern and the diff this gem emits leave the store in
      # *identical* states — same triples, same count — so no comparison of
      # before and after can distinguish them. That is precisely the property
      # the README's "writes only what changed" example is testing, so the
      # matcher subscribes to {PgRipple::Persistence::WRITE} and counts the
      # writes themselves.
      #
      # `by:` counts **facts changed**, not raw triples: a delete and an insert
      # on the same subject and predicate are one change, because replacing a
      # value is one thing happening. That is what makes the README's `by: 1`
      # the right number for `role: "engineer"` becoming `role: "manager"` —
      # two triples cross the wire, one fact moved — and it is what fails when
      # a strategy rewrites a whole four-property subject: four facts, not one.
      #
      # `inserting:` and `deleting:` are the raw triple counts, for when the
      # shape of the write is the thing under test.
      #
      # @example every form
      #   expect { … }.to change_triples                        # wrote something
      #   expect { … }.to change_triples(by: 1)                 # one fact moved
      #   expect { … }.to change_triples(inserting: 1, deleting: 1)
      #   expect { … }.not_to change_triples                    # wrote nothing
      class ChangeTriples
        include ::RSpec::Matchers::Composable

        # @return [Array<Hash>] the payloads of every write the block made
        attr_reader :writes

        # @param by [Integer, nil] facts changed
        # @param inserting [Integer, nil] triples asserted
        # @param deleting [Integer, nil] triples retracted
        def initialize(by: nil, inserting: nil, deleting: nil)
          @expected_facts = by
          @expected_inserted = inserting
          @expected_deleted = deleting
          @writes = []
        end

        # @return [Boolean]
        def supports_block_expectations? = true

        # @return [false] the counts are of an event, not of a value, so
        #   negating a specific count would be ambiguous — `not_to
        #   change_triples(by: 2)` is true of a write of three facts, which is
        #   never what anyone means.
        def supports_value_expectations? = false

        def matches?(block)
          capture(&block)

          return facts_changed.positive? if no_expectation?

          matches_count?(@expected_facts, facts_changed) &&
            matches_count?(@expected_inserted, inserted) &&
            matches_count?(@expected_deleted, deleted)
        end

        def does_not_match?(block)
          unless no_expectation?
            raise ArgumentError, "use `expect { }.not_to change_triples` with no arguments; " \
              "a negated count says almost nothing"
          end

          capture(&block)
          facts_changed.zero?
        end

        # Triples asserted.
        #
        # @return [Integer]
        def inserted
          writes.sum { |w| w[:inserted_count] }
        end

        # Triples retracted.
        #
        # @return [Integer]
        def deleted
          writes.sum { |w| w[:deleted_count] }
        end

        # Facts changed: the written triples, deduplicated by subject and
        # predicate across both directions.
        #
        # A `DELETE WHERE` names no triples — the server counts them and does
        # not report them — so its count is added raw. It is the whole-subject
        # sweep, which is never one fact anyway.
        #
        # @return [Integer]
        def facts_changed
          named = writes.flat_map { |w| w[:deleted] + w[:inserted] }
          unnamed = writes.sum { |w| w[:deleted_count] - w[:deleted].size }

          named.map { |s| [s.subject, s.predicate] }.uniq.size + unnamed
        end

        def description
          return "change triples" if no_expectation?

          "change triples #{expectations.join(", ")}"
        end

        def failure_message
          "expected the block to change triples #{expectations.join(", ")}, " \
            "but it #{actual_description}"
        end

        def failure_message_when_negated
          "expected the block not to change triples, but it #{actual_description}"
        end

        private

        def no_expectation?
          @expected_facts.nil? && @expected_inserted.nil? && @expected_deleted.nil?
        end

        def matches_count?(expected, actual)
          expected.nil? || values_match?(expected, actual)
        end

        def capture
          subscriber = ActiveSupport::Notifications.subscribe(Persistence::WRITE) do |*args|
            @writes << ActiveSupport::Notifications::Event.new(*args).payload
          end

          yield
        ensure
          ActiveSupport::Notifications.unsubscribe(subscriber)
        end

        def expectations
          [
            ("by #{@expected_facts}" unless @expected_facts.nil?),
            ("inserting #{@expected_inserted}" unless @expected_inserted.nil?),
            ("deleting #{@expected_deleted}" unless @expected_deleted.nil?)
          ].compact
        end

        def actual_description
          return "wrote nothing" if writes.empty?

          "changed #{facts_changed} fact(s), inserting #{inserted} and deleting #{deleted}:\n" +
            writes.flat_map { |w|
              w[:deleted].map { |s| "  - #{s.to_base}" } + w[:inserted].map { |s| "  + #{s.to_base}" }
            }.join("\n")
        end
      end

      # @see PgRipple::RSpec::Matchers::ChangeTriples
      def change_triples(by: nil, inserting: nil, deleting: nil)
        ChangeTriples.new(by: by, inserting: inserting, deleting: deleting)
      end
    end
  end
end

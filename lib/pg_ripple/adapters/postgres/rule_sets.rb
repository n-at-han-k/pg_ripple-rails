# frozen_string_literal: true

require "pg_ripple/rule_set"
require "pg_ripple/adapters/postgres/query_executor"

module PgRipple
  module Adapters
    class Postgres
      # Fetches Datalog rule sets from the postgres connection.
      #
      # Two catalogs, not one. `_pg_ripple.rule_sets` is the set itself
      # (`name`, `active`) and `_pg_ripple.rules` holds one row per rule with
      # the rule's source text. `load_rules` stores `rule_text` verbatim, so
      # re-joining the rules of a set in `id` order reproduces the program that
      # was loaded — this is the kind that round-trips best of the five.
      #
      # A rule set with no rules is skipped. `drop_rules` deletes from
      # `_pg_ripple.rules` and leaves the `_pg_ripple.rule_sets` row standing,
      # so an empty set is what a dropped rule set looks like — indistinguishable
      # from one that never existed. Dumping it would emit a
      # `create_ripple_rules` with an empty program.
      #
      # Rules are joined regardless of `rules.active`: a deactivated individual
      # rule is state the DSL has no way to express, and silently omitting it
      # from the dump would produce a schema.rb that loads a DIFFERENT program
      # than the migrations did. Dumping the whole program and losing only the
      # per-rule deactivation is the smaller lie.
      #
      # @api private
      class RuleSets
        # The query used to retrieve the rule sets considered dumpable into
        # `db/schema.rb`.
        #
        # Newline-joined because `load_rules` accepts a whitespace-separated
        # program and a rule already ends in " ." — see the Datalog syntax note
        # in docs/probe-results.md §0.
        RULE_SETS_WITH_RULES_QUERY = <<~SQL.freeze
          SELECT
              rs.name,
              rs.active,
              COALESCE(r.rules, '')     AS rules,
              COALESCE(r.rule_count, 0) AS rule_count
          FROM _pg_ripple.rule_sets rs
          LEFT JOIN LATERAL (
              SELECT
                  string_agg(rule_text, E'\\n' ORDER BY id) AS rules,
                  count(*)                                  AS rule_count
              FROM _pg_ripple.rules
              WHERE rule_set = rs.name
          ) r ON true
          WHERE COALESCE(r.rule_count, 0) > 0
          ORDER BY rs.name;
        SQL

        # Wraps #all as a static facade.
        #
        # @return [Array<PgRipple::RuleSet>]
        def self.all(connection)
          PgRipple::Adapters::Postgres::QueryExecutor.call(
            connection: connection,
            query: RULE_SETS_WITH_RULES_QUERY,
            model_class: PgRipple::RuleSet
          )
        end
      end
    end
  end
end

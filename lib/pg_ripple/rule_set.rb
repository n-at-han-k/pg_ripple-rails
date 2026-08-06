# frozen_string_literal: true

# `String#indent`, for laying the program out under its heredoc. Rails has it
# loaded long before the dumper runs; required explicitly for the same reason
# lib/pg_ripple.rb requires "active_record" rather than "rails".
require "active_support/core_ext/string/indent"

module PgRipple
  # A Datalog rule set, as `_pg_ripple.rule_sets` joined to its rules, and how
  # it is written back into `db/schema.rb`.
  #
  # `rules` is the newline-joined `rule_text` of every row in
  # `_pg_ripple.rules` for this set, in `id` order, which is the program
  # `load_rules` was given: pg_ripple stores each rule's source verbatim, so
  # this is the kind that round-trips best of the five.
  #
  # @api private
  class RuleSet
    include Comparable

    attr_reader :name, :rules, :active, :rule_count

    def initialize(row)
      @name = row.fetch("name")
      @rules = row.fetch("rules", "")
      @active = row.fetch("active", nil)
      @rule_count = row.fetch("rule_count", 0)
    end

    def <=>(other)
      name <=> other.name
    end

    def ==(other)
      name == other.name && rules == other.rules
    end

    # Dumped as `definition:`, not as a `version:`, for F(x)'s reason: a
    # dumped object has no version, because the catalog knows nothing about
    # the files under `db/ripple/rules`. The program is the one the rules were
    # loaded from, re-joined in `id` order.
    #
    # The heredoc is single-quoted (`<<-'DATALOG'`) so nothing in the program
    # is interpolated — a Datalog rule is full of `#` comments and `?x`
    # variables, and `#{` inside one must reach the server unchanged.
    #
    # `disable_ripple_rules` follows when the set is inactive, because
    # `load_rules` always produces an ACTIVE rule set. Without the second line,
    # a database rebuilt from this schema would run inference the source
    # database does not — a difference in the triples the store ends up
    # holding, not merely in what the catalog reports.
    #
    # @return [String] a `create_ripple_rules` call, indented for `schema.rb`
    def to_schema
      schema = <<~SCHEMA.indent(2)
        create_ripple_rules #{name.inspect}, definition: <<-'DATALOG'
        #{rules.indent(4).rstrip}
        DATALOG
      SCHEMA

      schema += "  disable_ripple_rules #{name.inspect}\n" if active == false

      schema.rstrip
    end
  end
end

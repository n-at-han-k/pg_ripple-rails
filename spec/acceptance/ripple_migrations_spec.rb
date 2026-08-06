# frozen_string_literal: true

require "rails_helper"

# `spec/pg_ripple/migration_dsl_spec.rb` proves the block records and inverts
# against a fake connection. This one proves the same migration really creates
# the objects on the way up and really removes them on the way down, against a
# live pg_ripple — because a rollback that records the right command and then
# fails to run it is still a broken rollback.
RSpec.describe "a `ripple do … end` migration" do
  around do |example|
    was = ActiveRecord::Migration.verbose
    ActiveRecord::Migration.verbose = false
    example.run
    ActiveRecord::Migration.verbose = was
  end

  let(:program) do
    "?x <https://example.org/ancestor> ?y :- ?x <https://example.org/parent> ?y ."
  end

  let(:migration) do
    definition = program

    Class.new(ActiveRecord::Migration::Current) {
      define_method(:change) do
        ripple do
          create_prefix :migspec, "https://migspec.example.org/"
          create_ruleset :migspec_rules, definition: definition
        end
      end
    }.new
  end

  def migrate(direction)
    ActiveRecord::Base.with_connection { |conn| migration.exec_migration(conn, direction) }
  end

  def prefix_names
    PgRipple.database.prefixes.map { |prefix| prefix.prefix.to_s }
  end

  def rule_set_names
    PgRipple.database.rule_sets.map { |set| set.name.to_s }
  end

  it "creates the objects on the way up" do
    migrate(:up)

    expect(prefix_names).to include("migspec")
    expect(rule_set_names).to include("migspec_rules")
  end

  it "removes them again on `db:rollback`" do
    migrate(:up)
    migrate(:down)

    expect(prefix_names).not_to include("migspec")
    expect(rule_set_names).not_to include("migspec_rules")
  end

  it "restores the prefix's expansion, which only `revert_to_expansion:` knows" do
    # The inversion of `create_prefix` is a `drop_prefix` carrying the
    # expansion, so the round trip up-down-up needs no second migration to say
    # what the prefix meant.
    migrate(:up)
    migrate(:down)
    migrate(:up)

    expansion = PgRipple.database.prefixes.find { |prefix| prefix.prefix.to_s == "migspec" }&.expansion

    expect(expansion).to eq("https://migspec.example.org/")
  end

  # Everything above calls `#exec_migration` directly, which is what
  # `ActiveRecord::Migrator` calls per migration — but it is not what a user
  # types. `bin/rails db:rollback` is
  # `ActiveRecord::MigrationContext#rollback`: it reads a *directory*, builds a
  # MigrationProxy per file, loads the class, records a `schema_migrations`
  # row on the way up and deletes it on the way down. An anonymous migration
  # class cannot travel that path at all, so this is the one example with a
  # migration on disk.
  #
  # What it adds over the three above: the block survives being loaded from a
  # file rather than defined in a closure, and the version bookkeeping is
  # really what decides `rollback` runs it.
  describe "driven by db:migrate and db:rollback themselves" do
    let(:context) do
      ActiveRecord::MigrationContext.new(
        File.expand_path("../dummy/db/ripple_migrate", __dir__)
      )
    end

    # Higher than the dummy schema's own `version:`, because `rollback` reverts
    # the *last applied* migration and the schema load already recorded one.
    let(:version) { 20260807000001 }

    it "creates on db:migrate and removes again on db:rollback" do
      context.migrate

      expect(context.get_all_versions).to include(version)
      expect(prefix_names).to include("migspec_task")
      expect(rule_set_names).to include("migspec_task_rules")

      context.rollback

      expect(context.get_all_versions).not_to include(version)
      expect(prefix_names).not_to include("migspec_task")
      expect(rule_set_names).not_to include("migspec_task_rules")
    end
  end
end

# frozen_string_literal: true

require "spec_helper"
require "pg_ripple"

# The whole point of `ripple do … end` is that it is a receiver we own, so the
# short names exist inside it and nowhere else. Two things have to be true for
# that to be worth having:
#
#   1. a rollback still inverts what is inside the block, through
#      ActiveRecord::Migration::CommandRecorder, exactly as it does for a
#      directly-written `create_ripple_*`; and
#   2. the short names really are absent everywhere else.
#
# Both are asserted here, with no database: a fake connection stands in for the
# adapter, so what is under test is the dispatch and the inversion rather than
# the extension. `spec/acceptance/ripple_migrations_spec.rb` runs the same
# migration up and down against a live pg_ripple.
RSpec.describe PgRipple::MigrationDsl do
  # A hand-written fake, not a double: ActiveRecord::Migration#revert decides
  # whether to build a CommandRecorder by asking whether the connection
  # responds to `revert`, and a double that answers "yes" to everything takes
  # the branch that skips recording altogether — the exact bug this file exists
  # to catch.
  let(:connection_class) do
    Class.new do
      attr_reader :calls

      def initialize
        @calls = []
      end

      (PgRipple::MigrationDsl::Receiver::STATEMENTS.values + [:execute]).each do |statement|
        define_method(statement) do |*args, **options|
          @calls << [statement, args, options]
          nil
        end
      end
    end
  end

  def migration_class(&change)
    Class.new(ActiveRecord::Migration::Current) do
      define_method(:change, &change)
    end
  end

  def run(migration, direction, connection)
    migration.exec_migration(connection, direction)
    connection.calls
  end

  before { PgRipple.load }

  around do |example|
    was = ActiveRecord::Migration.verbose
    ActiveRecord::Migration.verbose = false
    example.run
    ActiveRecord::Migration.verbose = was
  end

  let(:connection) { connection_class.new }

  describe "reversibility" do
    it "records the block's commands so `db:rollback` inverts them" do
      migration = migration_class do
        ripple do
          create_ruleset :org_rules, version: 1
        end
      end.new

      # `proper_table_name` stringifies the first argument on the replay path —
      # ActiveRecord::Migration#method_missing does that to everything it
      # forwards, and CommandRecorder#replay goes through it. Identical to what
      # a directly-written `drop_ripple_rules :org_rules` gets today.
      expect(run(migration, :down, connection)).to eq(
        [[:drop_ripple_rules, ["org_rules"], {}]]
      )
    end

    it "inverts in reverse order, so a block rolls back as a unit" do
      migration = migration_class do
        ripple do
          create_prefix :ex, "https://example.org/"
          create_ruleset :org_rules, version: 1
        end
      end.new

      expect(run(migration, :down, connection).map(&:first)).to eq(
        [:drop_ripple_rules, :drop_ripple_prefix]
      )
    end

    it "carries `revert_to_version:` through as `version:`, as it does today" do
      migration = migration_class do
        ripple do
          drop_ruleset :org_rules, revert_to_version: 2
        end
      end.new

      expect(run(migration, :down, connection)).to eq(
        [[:create_ripple_rules, ["org_rules"], {version: 2}]]
      )
    end

    it "exchanges the versions of an update, so a rolled-back update still sweeps" do
      migration = migration_class do
        ripple do
          update_shape :person, version: 2, revert_to_version: 1
        end
      end.new

      expect(run(migration, :down, connection)).to eq(
        [[:update_ripple_shapes, ["person"], {version: 1, revert_to_version: 2}]]
      )
    end

    it "is irreversible without a `revert_to_version:`, naming the short method" do
      migration = migration_class do
        ripple do
          drop_ruleset :org_rules
        end
      end.new

      expect { run(migration, :down, connection) }.to raise_error(
        ActiveRecord::IrreversibleMigration, /drop_ripple_rules/
      )
    end

    it "still runs forwards" do
      migration = migration_class do
        ripple do
          create_prefix :ex, "https://example.org/"
        end
      end.new

      expect(run(migration, :up, connection)).to eq(
        [[:create_ripple_prefix, [:ex, "https://example.org/"], {}]]
      )
    end
  end

  describe "the short names' scope" do
    it "does not define `create_shape` on a bare migration" do
      migration = migration_class do
        create_shape :person_shape
      end.new

      expect { run(migration, :up, connection) }.to raise_error(NoMethodError, /create_shape/)
    end

    it "does not define the short names on the adapter, where they would shadow" do
      adapter = ActiveRecord::ConnectionAdapters::AbstractAdapter

      PgRipple::MigrationDsl::Receiver::STATEMENTS.each do |short, long|
        expect(adapter.method_defined?(long)).to be(true), "expected #{long} on the adapter"
        expect(adapter.method_defined?(short)).to be(false), "#{short} is on the adapter and would shadow"
      end
    end

    it "adds exactly one name to ActiveRecord::Migration" do
      added = PgRipple::MigrationDsl.instance_methods

      expect(added).to eq([:ripple])
    end

    it "leaves the long names usable inside the block" do
      migration = migration_class do
        ripple do
          create_ripple_prefix :ex, "https://example.org/"
        end
      end.new

      expect(run(migration, :up, connection).map(&:first)).to eq([:create_ripple_prefix])
    end
  end

  describe "the receiver" do
    it "forwards anything it does not define to the migration" do
      migration = migration_class do
        ripple do
          execute "SELECT 1"
        end
      end.new

      expect(run(migration, :up, connection)).to eq([[:execute, ["SELECT 1"], {}]])
    end

    it "passes itself to a block that takes an argument" do
      migration = migration_class do
        ripple do |r|
          r.create_prefix :ex, "https://example.org/"
        end
      end.new

      expect(run(migration, :up, connection).map(&:first)).to eq([:create_ripple_prefix])
    end

    it "does not rewrite the first argument with `proper_table_name`" do
      # Migration#method_missing prefixes the first argument of everything it
      # forwards. A shape set is not a table, and in an engine that would look
      # for `acme_person` — so the block dispatches around it.
      allow(ActiveRecord::Base).to receive(:table_name_prefix).and_return("acme_")

      migration = migration_class do
        ripple do
          create_ruleset :org_rules, version: 1
        end
      end.new

      expect(run(migration, :up, connection).first[1]).to eq([:org_rules])
    end

    it "requires a block" do
      migration = migration_class do
        ripple
      end.new

      expect { run(migration, :up, connection) }.to raise_error(ArgumentError, /requires a block/)
    end
  end
end

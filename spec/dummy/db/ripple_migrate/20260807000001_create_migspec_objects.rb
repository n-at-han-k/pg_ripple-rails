# frozen_string_literal: true

# A migration on disk, because `db:rollback` will not look anywhere else: it is
# `ActiveRecord::MigrationContext#rollback`, which reads a directory, builds a
# MigrationProxy per file and loads the class out of it. An anonymous
# `Class.new(ActiveRecord::Migration::Current)` cannot be rolled back by that
# path at all, so the acceptance example that drives the real Rake task's
# machinery needs this file to exist.
#
# It lives under `db/ripple_migrate`, not `db/migrate`, so nothing else in the
# dummy application ever runs it.
class CreateMigspecObjects < ActiveRecord::Migration::Current
  def change
    ripple do
      create_prefix :migspec_task, "https://migspec-task.example.org/"
      create_ruleset :migspec_task_rules,
        definition: "?x <https://example.org/ancestor> ?y :- ?x <https://example.org/parent> ?y ."
    end
  end
end

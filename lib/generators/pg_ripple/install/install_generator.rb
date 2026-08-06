# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

require "pg_ripple/definition"

module PgRipple
  module Generators
    # `rails generate pg_ripple:install`.
    #
    # Four files: the initializer, the migration that installs the extension,
    # and the two directories that hold the documents migrations load — a SHACL
    # shape set is Turtle and a rule set is Datalog, so they live on disk in
    # their own languages rather than heredoc'd into a migration.
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Installs pg_ripple: an initializer, a migration, and the document directories."

      def create_initializer
        template "initializer.rb.tt", "config/initializers/pg_ripple.rb"
      end

      # Named `create_migration_file` and not `create_migration`, which is
      # `Rails::Generators::Migration`'s own method and the one
      # `migration_template` calls — a public method of that name here is a
      # Thor task that also shadows the machinery it is trying to use.
      def create_migration_file
        migration_template "install_pg_ripple.rb.tt", "db/migrate/install_pg_ripple.rb"
      end

      # `db/ripple/shapes` and `db/ripple/rules`, not `db/shapes` and
      # `db/rules`.
      #
      # {PgRipple::Definition} — the lookup `create_ripple_shapes` and
      # `create_ripple_rules` already go through — puts every kind of document
      # under one `db/ripple` directory, because "rules" and "views" are words
      # other things in a Rails app also want and a host application running
      # F(x) already has a `db/views` that means something else entirely. The
      # README's Install listing shows the top-level form; generating that
      # instead would create two directories nothing reads.
      def create_document_directories
        create_file File.join("db", PgRipple::Definition::DIRECTORY, PgRipple::Definition::SHAPES, ".keep")
        create_file File.join("db", PgRipple::Definition::DIRECTORY, PgRipple::Definition::RULES, ".keep")
      end

      private

      # The `[8.1]` in `ActiveRecord::Migration[8.1]`, taken from the Rails the
      # application is actually running rather than hard-coded.
      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end

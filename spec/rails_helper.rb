# frozen_string_literal: true

require "spec_helper"

ENV["RAILS_ENV"] ||= "test"

# The dummy app is only bootable when there is a database to boot it against —
# it connects at `initialize!` and its models reflect on real tables. Without
# `PG_RIPPLE_TEST_URL` the acceptance specs skip through the `:database` tag
# below rather than exploding at load time, which is why every reference to
# `Person` in `spec/acceptance` is inside an example and never at describe
# level.
if DatabaseHelper.available?
  DatabaseHelper.connect!

  require_relative "dummy/config/environment"

  ActiveRecord::Migration.verbose = false
  load File.expand_path("dummy/db/schema.rb", __dir__)

  # Loading the schema drops and recreates `people`, so its ids restart at 1 —
  # and the IRIs those ids mint are recycled. Anything a previous run committed
  # about `people/1` would silently attach itself to the next record numbered 1.
  # The transactional fixture means the suite itself never commits a triple, so
  # this only ever sweeps up after something that ran outside one, but it costs
  # a single statement and it is the difference between a repeatable suite and
  # a haunted one.
  #
  # `DELETE WHERE`, not `DROP EXTENSION … CASCADE`: dropping the extension
  # leaves the merge worker panicking in a loop with the dictionary empty,
  # accepting writes that never land (`docs/probe-lateral-join.md`).
  PgRipple.repository.sparql_update("DELETE WHERE { ?s ?p ?o }")
end

require "pg_ripple/rspec"

RSpec.configure do |config|
  config.include PgRipple::TestHelpers

  # Everything under spec/acceptance runs against the dummy app and a real
  # pg_ripple database. Tagging by path rather than by hand keeps the files
  # free of ceremony and makes it impossible to add one that quietly runs
  # without the database.
  config.define_derived_metadata(file_path: %r{/spec/acceptance/}) do |metadata|
    metadata[:database] = true
  end

  # Configuration is global and the unit specs point it at their own base URIs.
  # The suite order is random, so an acceptance example that inherited whatever
  # ran before it would mint IRIs under the wrong host. This puts back what
  # `spec/dummy/config/initializers/pg_ripple.rb` set.
  config.before(:each, :database) do |example|
    next unless example.metadata[:file_path].include?("/spec/acceptance/")

    PgRipple.configure do |c|
      c.base_uri = "https://app.example.com/"
      c.default_graph = nil
    end
  end
end

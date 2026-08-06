# frozen_string_literal: true

require "rails_helper"

# `spec/pg_ripple/plan_cache_spec.rb` drives the hazard through
# `repository.sparql`, which goes through
# {PgRipple::ConnectionLeasing#with_ripple_statement} and so marks the
# connection. That is not the exposed query.
#
# The exposed queries are the ones `docs/probe-cache-invalidation.md` §3 names:
# `Model.graph`, every `graph_has_many` reader and every property-path
# traversal. Every one of those runs `pg_ripple.sparql()` inside a
# `JOIN LATERAL` executed by *ActiveRecord*, not by this gem's adapter, so
# before {PgRipple::PlanCache::Invalidation#internal_exec_query} existed the
# connection was never marked: `poison!` returned early on `unless touched?`,
# the rollback hook no-oped, `recover!` never ran, and the backend answered
# that traversal with zero rows for the rest of its life.
#
# Measured on a live 0.128.0, on a fresh backend, before the fix:
#
#     alice.friends.count       -> touched? false
#     Person.graph.where(...)   -> touched? false
#     PgRipple.repository.count -> touched? true
#
# `:no_transaction`, because the hazard is a top-level rollback — see
# `spec/support/database.rb`. Nothing here commits.
RSpec.describe "the plan cache and the lateral join", :database, :no_transaction do
  def connection
    ActiveRecord::Base.lease_connection
  end

  # A backend this gem has said nothing to yet.
  def forget!
    raw = connection.respond_to?(:__getobj__) ? connection.__getobj__ : connection
    raw.instance_variable_set(PgRipple::PlanCache::TOUCHED, nil)
    raw.instance_variable_set(PgRipple::PlanCache::POISONED, nil)
  end

  after do
    PgRipple.repository.sparql_update("DELETE WHERE { ?s ?p ?o }")
    Person.delete_all
    Organization.delete_all
  end

  it "marks the connection for a graph_has_many traversal" do
    alice = Person.create!(name: "Alice")
    forget!

    alice.friends.count

    expect(PgRipple::PlanCache.touched?(connection)).to be(true)
  end

  it "marks the connection for a property-path traversal" do
    alice = Person.create!(name: "Alice")
    forget!

    alice.network.to_a

    expect(PgRipple::PlanCache.touched?(connection)).to be(true)
  end

  # `#count`, `#pluck` and `#exists?` never reach `#exec_queries` — they reach
  # the server through `select_all`. Hooking `#internal_exec_query` is what
  # covers all four spellings with one method.
  it "marks the connection for Model.graph, however the relation is drained" do
    Person.create!(name: "Alice")

    [
      -> { Person.graph.where(role: "engineer").to_a },
      -> { Person.graph.where(role: "engineer").count },
      -> { Person.graph.where(role: "engineer").pluck(:name) },
      -> { Person.graph.where(role: "engineer").exists? }
    ].each do |read|
      forget!
      read.call

      expect(PgRipple::PlanCache.touched?(connection)).to be(true)
    end
  end

  it "leaves a connection that has only run ordinary SQL alone" do
    Person.create!(name: "Alice")
    forget!

    Person.where(active: true).to_a

    expect(PgRipple::PlanCache.touched?(connection)).to be(false)
  end

  # The point of the marking: a rollback after a traversal has to poison the
  # connection, and the next traversal has to reset the cache before running.
  it "poisons on rollback and recovers on the next traversal" do
    Person.create!(name: "Alice")
    forget!

    ActiveRecord::Base.transaction do
      Person.graph.where(role: "engineer").to_a
      raise ActiveRecord::Rollback
    end

    expect(PgRipple::PlanCache.poisoned?(connection)).to be(true)

    Person.graph.where(role: "engineer").to_a

    expect(PgRipple::PlanCache.poisoned?(connection)).to be(false)
  end

  # The hook is a `prepend`, so it is a no-op — silently — if ActiveRecord ever
  # stops defining the method it wraps. `#internal_exec_query` has been the
  # adapter's query seam since Rails 7.1, which is this gem's floor; this is
  # what turns a version bump that moves it into a red spec rather than into a
  # connection that is never marked again.
  it "wraps a method ActiveRecord itself defines" do
    owners = ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.ancestors.select do |mod|
      mod.method_defined?(:internal_exec_query, false) ||
        mod.private_method_defined?(:internal_exec_query, false)
    end

    expect(owners).to include(PgRipple::PlanCache::Invalidation)
    expect(owners - [PgRipple::PlanCache::Invalidation]).not_to be_empty
  end

  # The reset is itself `SELECT pg_ripple.plan_cache_reset()`. Recognising a
  # traversal by `"pg_ripple"` rather than by the join-alias prefix would make
  # the recovery look like a statement that needs recovering, and recurse.
  it "does not mistake its own reset for a traversal" do
    expect(PgRipple::Relation.lateral?(PgRipple::PlanCache::RESET_SQL)).to be(false)
    expect(PgRipple::Relation.lateral?("SELECT pg_ripple.sparql($1)")).to be(false)
    expect(PgRipple::Relation.lateral?(Person.graph.where(role: "engineer").to_sql)).to be(true)
  end
end

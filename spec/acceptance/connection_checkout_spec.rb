# frozen_string_literal: true

require "rails_helper"

# `ActiveRecord::Base.connection` is the deprecated permanent-checkout API.
# Rails is moving towards `permanent_connection_checkout = :disallowed`, and
# under it the *whole gem* raised — reads, writes and migrations alike, and
# from inside an application's own `with_connection` block too, so there was no
# way to scope around it.
#
# Every path this gem takes to a connection now goes through
# `PgRipple::ConnectionLeasing#with_ripple_connection`, which is
# `ActiveRecord::Base.with_connection` (and `#connection` only on Rails 7.1,
# where it is neither deprecated nor disallowed). This spec is the proof: it
# turns the setting on and exercises the repository, the schema adapter, the
# model and a graph traversal, which between them cover every seam.
RSpec.describe "connection checkout", :database do
  before do
    skip "this Rails does not have permanent_connection_checkout" unless
      ActiveRecord.respond_to?(:permanent_connection_checkout=)
  end

  around do |example|
    previous = ActiveRecord.permanent_connection_checkout
    ActiveRecord.permanent_connection_checkout = :disallowed
    example.run
  ensure
    ActiveRecord.permanent_connection_checkout = previous
  end

  # The setting alone is not enough to make these examples honest, and that is
  # measurable: `#connection` raises only when the pool has no *permanent*
  # lease, and inside the suite's own transaction wrapper — itself a
  # `with_connection` block — it quietly returns the connection already checked
  # out. With the setting alone, reverting {PgRipple::ConnectionLeasing} to
  # `connectable.connection` left eight of these ten examples passing, and
  # which two failed depended on the seed.
  #
  # So `ActiveRecord::Base.connection` is made to raise unconditionally for the
  # duration of each example. That is what `:disallowed` *means* — the gem must
  # not call it — and it is a proposition a mutation can falsify: with the same
  # revert in place, every example below now fails.
  #
  # The guard example is exempt (`:real_connection`); it is testing the real
  # method.
  before do |example|
    next if example.metadata[:real_connection]

    allow(ActiveRecord::Base).to receive(:connection) do
      raise ActiveRecord::ActiveRecordError, "Called deprecated `ActiveRecord::Base.connection` method."
    end
  end

  # `:no_transaction`, because the suite's own transaction wrapper is itself a
  # `with_connection` block: inside one, `#connection` returns the connection
  # already checked out and does not raise. Outside it — a controller action, a
  # job, an example that has not opened a transaction — it raises, which is the
  # state every other example here is proving the gem survives.
  it "raises on the API this gem stopped using", :no_transaction, :real_connection do
    # The guard on the guard: if this stops raising, nothing below proves
    # anything.
    #
    # The release is needed because loading the dummy app's schema leaves a
    # permanent lease on this thread, and `#connection` only raises when there
    # is none — which is the state a fresh request or job starts in.
    ActiveRecord::Base.connection_pool.release_connection

    expect { ActiveRecord::Base.connection }
      .to raise_error(ActiveRecord::ActiveRecordError, /deprecated/)
  end

  it "reads the graph" do
    expect { PgRipple.repository.count }.not_to raise_error
  end

  it "runs a SPARQL SELECT" do
    expect { PgRipple.repository.sparql("SELECT ?s WHERE { ?s ?p ?o } LIMIT 1") }
      .not_to raise_error
  end

  it "runs a catalog read the schema dumper depends on" do
    expect { PgRipple.configuration.adapter.prefixes }.not_to raise_error
  end

  it "runs a migration statement" do
    expect { PgRipple.configuration.adapter.create_prefix("checkout", "https://checkout.test/") }
      .not_to raise_error
  ensure
    PgRipple.configuration.adapter.drop_prefix("checkout")
  end

  it "creates a node and reads its triples back" do
    person = nil

    expect { person = Person.create!(name: "Checkout", role: "engineer") }.not_to raise_error
    expect(person).to have_triple(RDF::Vocab::FOAF.name, "Checkout")
  end

  it "traverses a graph association" do
    alice = Person.create!(name: "Alice Checkout")
    bob = Person.create!(name: "Bob Checkout")
    alice.friends << bob

    expect { expect(alice.friends.pluck(:name)).to eq(["Bob Checkout"]) }.not_to raise_error
  end

  it "resets the plan cache" do
    expect(PgRipple.reset_plan_cache!).to be(true)
  end

  # The two seams that did not exist when this file was written. Both reach a
  # connection by their own route — a migration goes through
  # `ActiveRecord::Tasks::DatabaseTasks.migration_connection`, and the
  # preloader issues its `jsonld_frame` statement from inside `#exec_queries`
  # — so neither is covered by the examples above.
  it "runs a `ripple do … end` migration" do
    migration = Class.new(ActiveRecord::Migration::Current) {
      def change
        ripple do
          create_prefix :checkout_block, "https://checkout-block.test/"
        end
      end
    }.new

    # Deliberately *not* wrapped in `with_connection`: the migration has to
    # find its own connection, which is the thing under test.
    expect { migration.migrate(:up) }.not_to raise_error
    expect(PgRipple.database.prefixes.map { |p| p.prefix.to_s }).to include("checkout_block")

    expect { migration.migrate(:down) }.not_to raise_error
    expect(PgRipple.database.prefixes.map { |p| p.prefix.to_s }).not_to include("checkout_block")
  end

  it "preloads a graph association" do
    alice = Person.create!(name: "Alice Preload Checkout")
    bob = Person.create!(name: "Bob Preload Checkout")
    alice.friends << bob

    loaded = nil
    expect { loaded = Person.where(id: alice.id).graph_includes(:friends).to_a }.not_to raise_error

    expect(loaded.first.graph_association_loaded?(:friends)).to be(true)
    expect(loaded.first.friends.map(&:name)).to eq(["Bob Preload Checkout"])
  end
end

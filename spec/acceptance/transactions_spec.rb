# frozen_string_literal: true

require "rails_helper"

# README, "Transactions":
#
#     ActiveRecord::Base.transaction do
#       account = Account.create!(name: "Acme")
#       alice   = Person.create!(account:, name: "Alice Ng", role: "engineer")
#       alice.friends << Person.find_by(name: "Bob")
#       raise ActiveRecord::Rollback if over_quota?(account)
#     end
#
# "Nothing is written — not the row, not the triples." One connection, one
# transaction, so the graph cannot survive a rollback the row did not.
#
# One difference from the printed block, and it is Rails' rule rather than this
# gem's: `requires_new: true`. The suite already runs each example inside a
# transaction, and `raise ActiveRecord::Rollback` in a nested block that did
# *not* ask for a savepoint is swallowed and rolls nothing back. A host app
# writing the README's block at the top level gets a real transaction and needs
# no such flag.
RSpec.describe "transactions" do
  def over_quota?(_account) = true

  it "rolls the row and its triples back together" do
    bob = Person.create!(name: "Bob")
    alice_iri = nil

    ActiveRecord::Base.transaction(requires_new: true) do
      account = Account.create!(name: "Acme")
      alice = Person.create!(account: account, name: "Alice Ng", role: "engineer")
      alice.friends << bob
      alice_iri = alice.rdf_subject

      # Read-your-writes inside the transaction: both halves are there.
      expect(Person.find_by(name: "Alice Ng")).to eq(alice)
      expect(alice).to have_triple(EX.role, "engineer")
      expect(bob.friends).to be_empty
      expect(alice.friends.pluck(:name)).to eq(%w[Bob])

      raise ActiveRecord::Rollback if over_quota?(account)
    end

    expect(Person.find_by(name: "Alice Ng")).to be_nil
    expect(Account.find_by(name: "Acme")).to be_nil
    expect(PgRipple.repository.query([alice_iri, nil, nil]).to_a).to be_empty
    expect(PgRipple.repository.query([nil, nil, alice_iri]).to_a).to be_empty

    # Bob predates the transaction and is untouched by its rollback.
    expect(bob.reload.name).to eq("Bob")
    expect(bob).to have_triple(RDF::Vocab::FOAF.name, "Bob")
  end

  it "commits both halves when the transaction commits" do
    alice = nil

    ActiveRecord::Base.transaction(requires_new: true) do
      alice = Person.create!(name: "Alice Ng", role: "engineer")
    end

    expect(Person.find_by(name: "Alice Ng")).to eq(alice)
    expect(alice).to have_triple(EX.role, "engineer")
  end

  it "takes the graph write back when the SQL half raises afterwards" do
    iri = nil

    expect {
      ActiveRecord::Base.transaction(requires_new: true) do
        person = Person.create!(name: "Second", role: "engineer")
        iri = person.rdf_subject

        # A second row claiming the same IRI: the unique index rejects it, and
        # the graph write that already succeeded goes back with it.
        #
        # `#with_connection`, not `Person.connection`: the latter is the
        # deprecated permanent checkout and raises under
        # `permanent_connection_checkout = :disallowed`, which
        # `spec/pg_ripple/connection_checkout_spec.rb` turns on.
        Person.with_connection do |conn|
          conn.execute(<<~SQL)
            INSERT INTO people (name, iri, created_at, updated_at)
            VALUES ('dup', #{conn.quote(person.iri)}, now(), now())
          SQL
        end
      end
    }.to raise_error(ActiveRecord::RecordNotUnique)

    expect(PgRipple.repository.query([iri, nil, nil]).to_a).to be_empty
  end
end

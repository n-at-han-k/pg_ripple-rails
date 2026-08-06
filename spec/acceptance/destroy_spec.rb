# frozen_string_literal: true

require "rails_helper"

# README, "How writes work":
#
#     class Person < ApplicationRecord
#       graph dependent: :nullify_references    # also DELETE WHERE { ?s ?p <iri> }
#     end
#
# There is no foreign key in a graph, so nothing stops an edge pointing at a
# destroyed subject. The outbound half — the triples the subject asserts — is
# what any RDF library would remove. The inbound half is the one this option
# exists for, and it is the one a `belongs_to`-shaped mental model expects.
RSpec.describe "destroy" do
  it "sweeps inbound edges as well as outbound ones" do
    alice = Person.create!(name: "Alice Ng", role: "engineer")
    bob = Person.create!(name: "Bob")
    carol = Person.create!(name: "Carol")

    alice.friends << bob
    carol.friends << bob
    bob.friends << carol

    bob_iri = bob.rdf_subject

    expect(PgRipple.repository.query([nil, nil, bob_iri]).count).to eq(2)

    bob.destroy!

    expect(PgRipple.repository.query([bob_iri, nil, nil]).to_a).to be_empty
    expect(PgRipple.repository.query([nil, nil, bob_iri]).to_a).to be_empty

    expect(alice.friends).to be_empty
    expect(carol.friends).to be_empty
    expect(alice).to have_triple(EX.role, "engineer")
    expect(carol).to have_triple(RDF::Vocab::FOAF.name, "Carol")
    expect(Person.exists?(bob.id)).to be(false)
  end

  it "rolls the sweep back with the transaction" do
    alice = Person.create!(name: "Alice Ng")
    bob = Person.create!(name: "Bob")
    alice.friends << bob

    ActiveRecord::Base.transaction(requires_new: true) do
      bob.destroy!
      expect(alice.friends).to be_empty
      raise ActiveRecord::Rollback
    end

    expect(Person.exists?(bob.id)).to be(true)
    expect(alice.friends.pluck(:name)).to eq(%w[Bob])
  end
end

# frozen_string_literal: true

require "rails_helper"

# README, "Testing":
#
#     it "writes only what changed" do
#       alice = create(:person, role: "engineer")
#       expect { alice.update!(role: "manager") }.to change_triples(by: 1)
#     end
#
# and README, "How writes work": the update is a `DELETE DATA` / `INSERT DATA`
# pair naming exactly the triple that moved, not a `DELETE WHERE` sweep and a
# re-assertion of everything.
RSpec.describe "writes" do
  it "writes only what changed" do
    alice = Person.create!(name: "Alice Ng", role: "engineer")

    expect { alice.update!(role: "manager") }.to change_triples(by: 1)
  end

  it "puts exactly one triple pair on the wire" do
    alice = Person.create!(name: "Alice Ng", role: "engineer")

    expect { alice.update!(role: "manager") }
      .to change_triples(by: 1, inserting: 1, deleting: 1)

    expect(alice).to have_triple(EX.role, "manager")
    expect(alice).not_to have_triple(EX.role, "engineer")
    expect(alice).to have_triple(RDF::Vocab::FOAF.name, "Alice Ng")
  end

  it "emits DELETE DATA / INSERT DATA, not DELETE WHERE" do
    alice = Person.create!(name: "Alice Ng", role: "engineer")
    updates = []
    allow(PgRipple.repository).to receive(:sparql_update).and_wrap_original do |original, update|
      updates << update
      original.call(update)
    end

    alice.update!(role: "manager")

    expect(updates.size).to eq(1)
    expect(updates.first).to include(%(DELETE DATA {\n  <#{alice.iri}> <#{EX.role}> "engineer" .\n}))
    expect(updates.first).to include(%(INSERT DATA {\n  <#{alice.iri}> <#{EX.role}> "manager" .\n}))
    expect(updates.first).not_to include("DELETE WHERE")
  end

  it "writes nothing when nothing moved" do
    alice = Person.create!(name: "Alice Ng", role: "engineer")

    expect {
      alice.role = "engineer"
      alice.save!
    }.not_to change_triples
  end

  it "mirrors a column edit into the graph and leaves the others alone" do
    alice = Person.create!(name: "Alice Ng", email: "alice@example.com", role: "engineer")

    expect { alice.update!(name: "Alice Ngata") }.to change_triples(by: 1)

    expect(alice).to have_triple(RDF::Vocab::FOAF.name, "Alice Ngata")
    expect(alice).to have_triple(RDF::Vocab::FOAF.mbox, RDF::URI("mailto:alice@example.com"))
    expect(alice).to have_triple(EX.role, "engineer")
  end

  it "writes the README's Turtle on create" do
    alice = Person.create!(name: "Alice Ng", email: "alice@example.com")
    alice.role = "engineer"
    alice.save!

    expect(alice.iri).to eq("https://app.example.com/people/#{alice.id}")
    expect(ripple_triples(alice).map { |s| s.to_base.strip }).to contain_exactly(
      %(<#{alice.iri}> <#{RDF.type}> <#{RDF::Vocab::FOAF.Person}> .),
      %(<#{alice.iri}> <#{RDF::Vocab::FOAF.name}> "Alice Ng" .),
      %(<#{alice.iri}> <#{RDF::Vocab::FOAF.mbox}> <mailto:alice@example.com> .),
      %(<#{alice.iri}> <#{EX.role}> "engineer" .)
    )
  end
end

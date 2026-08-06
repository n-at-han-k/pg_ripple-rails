# frozen_string_literal: true

require "spec_helper"
require "pg_ripple/rspec"
require "rdf/vocab"

if DatabaseHelper.available?
  DatabaseHelper.connect!
  DatabaseHelper.execute(<<~SQL)
    DROP TABLE IF EXISTS write_spec_people;
    CREATE TABLE write_spec_people (
      id      serial PRIMARY KEY,
      name    text,
      born_on date,
      note    text,
      iri     text UNIQUE
    );
  SQL
end

RSpec.describe PgRipple::Persistence::DiffStrategy, :database do
  include PgRipple::TestHelpers

  let(:ex) { RDF::Vocabulary.new("https://app.example.com/ns#") }

  before do
    PgRipple.configure { |c| c.base_uri = "https://app.example.com/" }
  end

  # A fresh anonymous model per example: `graph` generates methods and
  # constants, and a leaked one would make the suite order-dependent.
  def person_class(**options)
    vocab = ex
    klass = Class.new(ActiveRecord::Base) do
      self.table_name = "write_spec_people"
      include PgRipple::Node
    end
    stub_const("Person", klass)
    klass.graph(type: RDF::Vocab::FOAF.Person, iri: ->(p) { "people/#{p.id}" }, **options) do
      property :name, predicate: RDF::Vocab::FOAF.name, from: :name
      property :birthdate, predicate: RDF::Vocab::FOAF.birthday, from: :born_on
      property :role, predicate: vocab.role
    end
    klass
  end

  def alice
    @alice ||= begin
      person = person_class.create!(name: "Alice Ng")
      person.role = "engineer"
      person.save!
      person
    end
  end

  # ---------------------------------------------------------------- README

  describe "the README's acceptance criteria" do
    it "writes only what changed" do
      alice

      expect { alice.update!(name: "Alice N") }.to change_triples(by: 1)
    end

    it "replaces a graph-only value with one delete and one insert" do
      alice

      expect {
        alice.role = "manager"
        alice.save!
      }.to change_triples(by: 1).and change_triples(inserting: 1, deleting: 1)
    end

    it "leaves the unchanged triples alone" do
      alice
      before = ripple_triples(alice).to_set

      alice.role = "manager"
      alice.save!

      expect(alice).to have_triple(ex.role, "manager")
      expect(alice).to have_triple(RDF::Vocab::FOAF.name, "Alice Ng")
      expect(alice).to have_triple(RDF.type, RDF::Vocab::FOAF.Person)
      expect(ripple_triples(alice).size).to eq(before.size)
    end

    it "emits the README's DELETE DATA ; INSERT DATA and no whole-subject sweep" do
      alice
      captured = []
      allow(PgRipple.repository).to receive(:sparql_update).and_wrap_original do |m, text|
        captured << text
        m.call(text)
      end

      alice.role = "manager"
      alice.save!

      expect(captured.size).to eq(1)
      expect(captured.first).to include(%(DELETE DATA {\n  <#{alice.iri}> <#{ex.role}> "engineer" .\n}))
      expect(captured.first).to include(%(INSERT DATA {\n  <#{alice.iri}> <#{ex.role}> "manager" .\n}))
      expect(captured.first).not_to include("DELETE WHERE")
    end
  end

  # ------------------------------------------------------------------ base

  describe "creating" do
    it "writes the type, the mirrored columns and the graph-only values" do
      person = person_class.create!(name: "Bob", born_on: Date.new(1990, 1, 2))

      expect(person).to have_triple(RDF.type, RDF::Vocab::FOAF.Person)
      expect(person).to have_triple(RDF::Vocab::FOAF.name, "Bob")
      expect(person).to have_triple(RDF::Vocab::FOAF.birthday, Date.new(1990, 1, 2))
    end

    it "moves in-memory values off the blank node onto the minted IRI" do
      person = person_class.new(name: "Bob")
      person.role = "engineer"
      person.save!

      expect(person.rdf_subject).to eq(RDF::URI("https://app.example.com/people/#{person.id}"))
      expect(person).to have_triple(ex.role, "engineer")
      expect(ripple_repository.query([nil, ex.role, nil]).map(&:subject)).to all(be_uri)
    end
  end

  describe "saving nothing" do
    it "writes nothing when no attribute moved" do
      alice

      expect { alice.save! }.not_to change_triples
    end

    it "writes nothing when a graph value is reassigned to what it already was" do
      alice

      expect {
        alice.role = "engineer"
        alice.save!
      }.not_to change_triples
    end

    it "writes nothing when a column unrelated to the graph changes" do
      alice

      expect { alice.update!(note: "hello") }.not_to change_triples
    end
  end

  describe "a record loaded fresh from the database" do
    it "does not re-assert the triples it just read" do
      alice
      reloaded = alice.class.find(alice.id)
      reloaded.rdf_source # force the load

      expect { reloaded.save! }.not_to change_triples
    end
  end

  # -------------------------------------------------------------- destroy

  describe "destroying" do
    it "retracts the subject's triples" do
      alice
      subject = RDF::URI(alice.iri)

      alice.destroy!

      expect(ripple_repository.query([subject, nil, nil]).to_a).to be_empty
    end

    it "leaves the inbound edges alone by default" do
      alice
      bob = person_class.create!(name: "Bob")
      ripple_repository << [RDF::URI(bob.iri), RDF::Vocab::FOAF.knows, RDF::URI(alice.iri)]

      alice.destroy!

      expect(ripple_repository.query([nil, nil, RDF::URI(alice.iri)]).to_a.size).to eq(1)
    end

    it "retracts the inbound edges under dependent: :nullify_references" do
      klass = person_class(dependent: :nullify_references)
      target = klass.create!(name: "Alice Ng")
      bob = klass.create!(name: "Bob")
      ripple_repository << [RDF::URI(bob.iri), RDF::Vocab::FOAF.knows, RDF::URI(target.iri)]

      target.destroy!

      expect(ripple_repository.query([nil, nil, RDF::URI(target.iri)]).to_a).to be_empty
    end

    it "refuses a dependent: it does not implement, rather than failing open" do
      expect { person_class(dependent: :destroy_all_the_things) }
        .to raise_error(ArgumentError, /nullify_references/)
    end
  end

  # ---------------------------------------------------- opting back in

  describe "amending a mapping with a second graph call" do
    # The README declares `dependent:` and `persistence_strategy:` in their own
    # `graph` line, separate from the block that declared the properties.
    it "keeps the properties the first call declared" do
      klass = person_class
      klass.graph(dependent: :nullify_references)

      expect(klass.graph_schema.names).to eq(%i[name birthdate role])
      expect(klass.graph_schema).to be_nullify_references
      expect(klass.graph_schema.types).to eq([RDF::Vocab::FOAF.Person])
    end

    it "accepts a blockless declaration with no properties at all" do
      klass = Class.new(ActiveRecord::Base) do
        self.table_name = "write_spec_people"
        include PgRipple::Node
      end
      stub_const("LegacyThing", klass)
      klass.graph(persistence_strategy: ActiveTriples::RepositoryStrategy)

      expect(klass.graph_schema).not_to be_diffing
      expect(klass.graph_schema.names).to be_empty
    end
  end

  describe "graph persistence_strategy: ActiveTriples::RepositoryStrategy" do
    it "rewrites the whole subject, which is what the README warns about" do
      klass = person_class(persistence_strategy: ActiveTriples::RepositoryStrategy)
      person = klass.create!(name: "Alice Ng")
      person.role = "engineer"
      person.save!

      matcher = change_triples
      matcher.matches?(-> {
        person.role = "manager"
        person.save!
      })

      # name and rdf:type never moved, and were written anyway.
      expect(matcher.facts_changed).to be > 1
      expect(person).to have_triple(ex.role, "manager")
      expect(person).to have_triple(RDF::Vocab::FOAF.name, "Alice Ng")
    end
  end

  # ------------------------------------------------------- transactions

  describe "transactions" do
    it "rolls the triples back with the row" do
      created = nil

      ActiveRecord::Base.transaction(requires_new: true) do
        created = person_class.create!(name: "Ephemeral")
        expect(created).to have_triple(RDF::Vocab::FOAF.name, "Ephemeral")
        raise ActiveRecord::Rollback
      end

      expect(ripple_repository.query([RDF::URI(created.iri), nil, nil]).to_a).to be_empty
      expect(person_class.where(id: created.id)).to be_empty
    end

    it "takes the graph write with a failed save" do
      klass = person_class
      alice

      expect {
        klass.transaction(requires_new: true) do
          other = klass.create!(name: "Clash")
          other.update_column(:iri, alice.iri) # violates the unique index on the next insert
          klass.create!(name: "Clash 2").update_column(:iri, alice.iri)
        end
      }.to raise_error(ActiveRecord::RecordNotUnique)

      expect(ripple_repository.query([nil, RDF::Vocab::FOAF.name, RDF::Literal("Clash")]).to_a)
        .to be_empty
    end
  end
end

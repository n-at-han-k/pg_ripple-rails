# frozen_string_literal: true

require "spec_helper"
require "rdf/vocab"

if DatabaseHelper.available?
  DatabaseHelper.connect!
  DatabaseHelper.execute(<<~SQL)
    DROP TABLE IF EXISTS node_spec_people;
    CREATE TABLE node_spec_people (
      id      serial PRIMARY KEY,
      name    text,
      email   text,
      born_on date,
      active  boolean DEFAULT true,
      role    text,
      iri     text UNIQUE
    );
    DROP TABLE IF EXISTS node_spec_widgets;
    CREATE TABLE node_spec_widgets (id serial PRIMARY KEY, label text);
  SQL
end

# Guarded because the dummy app's initializer defines the same constant at the
# same IRI, and the suite order decides which of them gets there first.
EX = RDF::Vocabulary.new("https://app.example.com/ns#") unless defined?(EX)

RSpec.describe PgRipple::Node, :database do
  before do
    PgRipple.configure { |c| c.base_uri = "https://app.example.com/" }
  end

  # A fresh anonymous model per example: `graph` generates methods and
  # constants, and a leaked one would make the suite order-dependent.
  def person_class(&block)
    klass = Class.new(ActiveRecord::Base) do
      self.table_name = "node_spec_people"
      include PgRipple::Node
    end
    stub_const("Person", klass)
    klass.graph(type: RDF::Vocab::FOAF.Person, iri: ->(p) { "people/#{p.id}" }) do
      property :name, predicate: RDF::Vocab::FOAF.name, from: :name
      property :birthdate, predicate: RDF::Vocab::FOAF.birthday, from: :born_on
      property :nickname, predicate: RDF::Vocab::FOAF.nick
      instance_eval(&block) if block
    end
    klass
  end

  describe "the graph macro" do
    it "records the declared types and properties" do
      schema = person_class.graph_schema

      expect(schema.types).to eq([RDF::Vocab::FOAF.Person])
      expect(schema.names).to eq(%i[name birthdate nickname])
      expect(schema[:name].predicate).to eq(RDF::Vocab::FOAF.name)
      expect(schema[:name].from).to eq(:name)
      expect(schema[:nickname]).not_to be_mirrored
    end

    it "accepts a PgRipple::Path as a predicate" do
      ex = PgRipple::Path.vocabulary(EX, prefix: :ex)
      klass = person_class { property :role, predicate: ex.role, from: :role }

      expect(klass.graph_schema[:role].predicate).to eq(EX.role)
    end

    it "refuses a predicate that is not an IRI" do
      expect {
        person_class { property :bad, predicate: "not an iri" }
      }.to raise_error(ArgumentError, /not a valid IRI/)
    end

    # The seam this example was written around is now closed:
    # PgRipple::Associations always defines `graph_relation`, so a bare `graph`
    # is the query entry point rather than an error.
    it "returns the graph relation when called without a block" do
      klass = person_class

      expect(klass.graph).to be_a(PgRipple::Relation)
      expect(klass.graph.model).to eq(klass)
    end
  end

  describe "unknown properties" do
    it "raises PgRipple::UnknownProperty by name" do
      person = person_class.new

      expect { person.ripple_read(:rle) }
        .to raise_error(PgRipple::UnknownProperty, /unknown graph property :rle/)
    end

    it "carries the offending name on the error" do
      error = person_class.graph_schema.fetch(:rle)
    rescue PgRipple::UnknownProperty => e
      expect(e.name).to eq(:rle)
    else
      raise "expected UnknownProperty, got #{error.inspect}"
    end

    it "raises for an unknown predicate" do
      expect { person_class.graph_schema.fetch_predicate(EX.nope) }
        .to raise_error(PgRipple::UnknownProperty)
    end

    it "finds a property by its predicate" do
      schema = person_class.graph_schema
      expect(schema.fetch_predicate(RDF::Vocab::FOAF.name).name).to eq(:name)
    end
  end

  describe "#iri and #rdf_subject" do
    it "is nil before the record is saved" do
      expect(person_class.new(name: "Alice Ng").iri).to be_nil
    end

    it "is a blank node subject before the record is saved" do
      expect(person_class.new.rdf_subject).to be_a(RDF::Node)
    end

    it "is minted on create and persisted to the iri column" do
      alice = person_class.create!(name: "Alice Ng", email: "alice@example.com")

      expect(alice.iri).to eq("https://app.example.com/people/#{alice.id}")
      expect(alice.rdf_subject).to eq(RDF::URI("https://app.example.com/people/#{alice.id}"))
      expect(alice.reload.read_attribute(:iri)).to eq("https://app.example.com/people/#{alice.id}")
    end

    it "reads the stored column rather than re-minting" do
      alice = person_class.create!(name: "Alice Ng")
      alice.update_column(:iri, "https://elsewhere.example.com/p/9")

      expect(alice.reload.iri).to eq("https://elsewhere.example.com/p/9")
    end

    it "adds the missing trailing slash rather than eating a base path segment" do
      PgRipple.configure { |c| c.base_uri = "https://app.example.com/tenant" }
      alice = person_class.create!(name: "Alice Ng")

      expect(alice.iri).to eq("https://app.example.com/tenant/people/#{alice.id}")
    end

    it "raises when base_uri is unset" do
      PgRipple.configure { |c| c.base_uri = nil }

      expect { person_class.create!(name: "Alice Ng") }
        .to raise_error(PgRipple::IriError, /base_uri/)
    end

    it "raises when the table has no iri column" do
      klass = Class.new(ActiveRecord::Base) do
        self.table_name = "node_spec_widgets"
        include PgRipple::Node
      end
      stub_const("Widget", klass)
      klass.graph(type: EX.Widget, iri: ->(w) { "widgets/#{w.id}" }) do
        property :label, predicate: EX.label, from: :label
      end

      expect { klass.create!(label: "x") }.to raise_error(PgRipple::IriError, /iri column/)
    end

    it "accepts an absolute IRI from the lambda" do
      klass = person_class
      klass.graph_schema.instance_variable_set(:@iri_template, ->(p) { "urn:person:#{p.id}" })
      alice = klass.create!(name: "Alice Ng")

      expect(alice.iri).to eq("urn:person:#{alice.id}")
    end
  end

  describe "mirrored properties (from:)" do
    it "does not generate a reader that shadows the column of the same name" do
      klass = person_class
      expect(klass.const_get(:GeneratedGraphMethods).instance_methods).not_to include(:name)
      expect(klass.const_get(:GeneratedGraphMethods).instance_methods).to include(:name_values)

      expect(klass.new(name: "Alice Ng").name).to eq("Alice Ng")
    end

    it "generates a reader and writer when the property is named differently" do
      person = person_class.new
      person.birthdate = Date.new(1990, 1, 2)

      expect(person.birthdate).to eq(Date.new(1990, 1, 2))
      expect(person.read_attribute(:born_on)).to eq(Date.new(1990, 1, 2))
    end

    it "answers _values from the column" do
      expect(person_class.new(name: "Alice Ng").name_values).to eq(["Alice Ng"])
      expect(person_class.new.name_values).to eq([])
    end
  end

  describe "graph-only properties" do
    it "reads back what was set in memory" do
      person = person_class.new
      person.nickname = "Al"

      expect(person.nickname).to eq("Al")
      expect(person.nickname_values).to eq(["Al"])
    end

    it "is multi-valued underneath" do
      person = person_class.new
      person.nickname = ["Al", "Ali"]

      expect(person.nickname_values).to match_array(["Al", "Ali"])
      expect(person.nickname).to be_a(String)
    end

    it "is empty when nothing was set" do
      expect(person_class.new.nickname_values).to eq([])
      expect(person_class.new.nickname).to be_nil
    end

    it "lands on the record's subject in the graph" do
      alice = person_class.create!(name: "Alice Ng")
      alice.nickname = "Al"

      statement = alice.rdf_source.statements.find { |s| s.predicate == RDF::Vocab::FOAF.nick }
      expect(statement.subject).to eq(RDF::URI(alice.iri))
    end

    it "moves in-memory values from the blank node onto the minted IRI" do
      person = person_class.new(name: "Alice Ng")
      person.nickname = "Al"
      expect(person.rdf_subject).to be_a(RDF::Node)

      person.save!

      expect(person.rdf_subject).to eq(RDF::URI(person.iri))
      expect(person.nickname).to eq("Al")
      expect(person.rdf_source.statements.map(&:subject).uniq).to eq([RDF::URI(person.iri)])
    end

    it "carries the declared rdf:type" do
      types = person_class.new.rdf_source.get_values(:type).to_a
      expect(types).to eq([RDF::Vocab::FOAF.Person])
    end
  end

  describe "cast:" do
    it "coerces through a class" do
      klass = person_class { property :homepage, predicate: RDF::Vocab::FOAF.homepage, cast: RDF::URI }
      person = klass.new
      person.homepage = "https://example.com/alice"

      expect(person.homepage).to eq(RDF::URI("https://example.com/alice"))
    end

    it "coerces through a callable" do
      klass = person_class do
        property :mbox, predicate: RDF::Vocab::FOAF.mbox, cast: ->(v) { RDF::URI("mailto:#{v}") }
      end
      person = klass.new
      person.mbox = "alice@example.com"

      expect(person.mbox).to eq(RDF::URI("mailto:alice@example.com"))
    end

    it "refuses a cast that produces an invalid IRI" do
      klass = person_class { property :mbox, predicate: RDF::Vocab::FOAF.mbox, cast: RDF::URI }

      expect { klass.new.mbox = "alice@example.com" }
        .to raise_error(PgRipple::InvalidTerm, /not a valid IRI/)
    end
  end

  describe "column collisions" do
    it "refuses a graph-only property that would shadow a column" do
      klass = person_class { property :role, predicate: EX.role }

      expect { klass.new.role = "engineer" }
        .to raise_error(PgRipple::PropertyCollision, /would shadow/)
    end

    it "refuses a from: naming a column that does not exist" do
      klass = person_class { property :salary, predicate: EX.salary, from: :no_such_column }

      expect { klass.new.salary = 1 }
        .to raise_error(PgRipple::PropertyCollision, /not a column/)
    end
  end

  describe "#rdf_source" do
    it "loads the subject's triples out of the store for a persisted record" do
      alice = person_class.create!(name: "Alice Ng")
      PgRipple.repository.insert(
        RDF::Statement(RDF::URI(alice.iri), RDF::Vocab::FOAF.nick, RDF::Literal("Al"))
      )

      expect(person_class.find(alice.id).nickname).to eq("Al")
    end

    it "is discarded on reload" do
      alice = person_class.create!(name: "Alice Ng")
      alice.nickname = "Al"

      expect(alice.reload.nickname).to be_nil
    end

    it "dumps as N-Triples" do
      alice = person_class.create!(name: "Alice Ng")
      alice.nickname = "Al"

      expect(alice.rdf_source.dump(:ntriples))
        .to include("<#{alice.iri}> <http://xmlns.com/foaf/0.1/nick> \"Al\" .")
    end
  end
end

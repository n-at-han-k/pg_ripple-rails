# frozen_string_literal: true

require "spec_helper"

RSpec.describe PgRipple::Persistence::Update do
  let(:ex) { RDF::Vocabulary.new("https://app.example.com/ns#") }
  let(:alice) { RDF::URI("https://app.example.com/people/1") }

  describe "the README's diff" do
    it "emits DELETE DATA then INSERT DATA, and nothing else" do
      update = described_class.new
      update.delete_data([[alice, ex.role, RDF::Literal("engineer")]])
      update.insert_data([[alice, ex.role, RDF::Literal("manager")]])

      expect(update.to_s).to eq(<<~SPARQL.strip)
        DELETE DATA {
          <https://app.example.com/people/1> <https://app.example.com/ns#role> "engineer" .
        } ;
        INSERT DATA {
          <https://app.example.com/people/1> <https://app.example.com/ns#role> "manager" .
        }
      SPARQL
    end
  end

  it "is empty until something is written to it" do
    expect(described_class.new).to be_empty
  end

  it "omits an operation with no statements rather than emitting an empty block" do
    update = described_class.new
    update.delete_data([])
    update.insert_data([[alice, ex.role, RDF::Literal("manager")]])

    expect(update.to_s).not_to include("DELETE DATA")
  end

  describe "escaping" do
    it "escapes a literal that would otherwise close the block early" do
      update = described_class.new
      update.insert_data([[alice, ex.note, RDF::Literal(%(a " } \n <b>))]])

      expect(update.to_s).to include(%(<https://app.example.com/ns#note> "a \\" } \\n <b>" .))
    end

    it "keeps a datatype" do
      update = described_class.new
      update.insert_data([[alice, ex.age, RDF::Literal(30)]])

      expect(update.to_s)
        .to include(%("30"^^<http://www.w3.org/2001/XMLSchema#integer>))
    end

    it "keeps a language tag" do
      update = described_class.new
      update.insert_data([[alice, ex.name, RDF::Literal("Alice", language: :en)]])

      expect(update.to_s).to include(%("Alice"@en))
    end

    # SPARQL's IRIREF production has no UCHAR, so there is no escape and no
    # honest rendering — the same finding the property-path handler raises on.
    it "refuses an IRI SPARQL cannot express" do
      update = described_class.new

      expect {
        update.insert_data([[RDF::URI("https://x/a>b"), ex.role, RDF::Literal("x")]])
      }.to raise_error(ArgumentError, /IRIREF production/)
    end
  end

  describe "blank nodes" do
    it "refuses one in DELETE DATA" do
      expect {
        described_class.new.delete_data([[RDF::Node.new("b1"), ex.role, RDF::Literal("x")]])
      }.to raise_error(described_class::Unwritable, /blank node/)
    end

    it "allows one in INSERT DATA, where SPARQL means a fresh node" do
      update = described_class.new
      update.insert_data([[RDF::Node.intern("b1"), ex.role, RDF::Literal("x")]])

      expect(update.to_s).to include("_:b1")
    end
  end

  describe "DELETE WHERE" do
    it "sweeps a subject" do
      expect(described_class.new.delete_where(subject: alice).to_s).to eq(<<~SPARQL.strip)
        DELETE WHERE {
          <https://app.example.com/people/1> ?p ?o .
        }
      SPARQL
    end

    it "sweeps the references to a subject, which is dependent: :nullify_references" do
      expect(described_class.new.delete_where(object: alice).to_s)
        .to include("?s ?p <https://app.example.com/people/1> .")
    end
  end

  describe "a named graph" do
    it "wraps every operation in a GRAPH block" do
      update = described_class.new(graph_name: "https://app.example.com/tenant1")
      update.insert_data([[alice, ex.role, RDF::Literal("manager")]])

      expect(update.to_s).to eq(<<~SPARQL.strip)
        INSERT DATA {
          GRAPH <https://app.example.com/tenant1> {
            <https://app.example.com/people/1> <https://app.example.com/ns#role> "manager" .
          }
        }
      SPARQL
    end

    # Term.graph_argument strips them; a graph IRI in SPARQL text needs them.
    it "accepts a graph name that already wears angle brackets" do
      update = described_class.new(graph_name: "<https://app.example.com/tenant1>")
      update.insert_data([[alice, ex.role, RDF::Literal("x")]])

      expect(update.to_s).to include("GRAPH <https://app.example.com/tenant1> {")
    end
  end
end

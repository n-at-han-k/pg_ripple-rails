# frozen_string_literal: true

require "spec_helper"
require "sparql"

RSpec.describe PgRipple::Query do
  let(:foaf) { PgRipple::Path.vocabulary("http://xmlns.com/foaf/0.1/", prefix: "foaf") }
  let(:ex) { PgRipple::Path.vocabulary("https://app.example.com/ns#", prefix: "ex") }

  # String equality proves the right characters. Parsing proves the right
  # query — and every one of these is a string this gem hands to a server.
  def algebra(query)
    SPARQL.parse(query.to_s).to_sxp
  end

  it "projects one distinct subject" do
    query = described_class.new
    query.type(RDF::URI("http://xmlns.com/foaf/0.1/Person"))

    expect(query.to_s).to eq(<<~SPARQL)
      SELECT DISTINCT ?iri
      WHERE {
        ?iri a <http://xmlns.com/foaf/0.1/Person> .
      }
    SPARQL
    expect(algebra(query)).to include("distinct")
  end

  it "renders the README's equality query" do
    query = described_class.new
    query.type(RDF::URI("http://xmlns.com/foaf/0.1/Person"))
    query.equal(ex.role, RDF::Literal("engineer"))

    expect(query.to_s).to eq(<<~SPARQL)
      PREFIX ex: <https://app.example.com/ns#>
      SELECT DISTINCT ?iri
      WHERE {
        ?iri a <http://xmlns.com/foaf/0.1/Person> .
        ?iri ex:role "engineer" .
      }
    SPARQL
    expect { algebra(query) }.not_to raise_error
  end

  it "declares a PREFIX for every prefix a path actually used" do
    query = described_class.new
    query.traverse(from: RDF::URI("https://app.example.com/people/1"), path: +foaf.knows)

    expect(query.to_s).to start_with("PREFIX foaf: <http://xmlns.com/foaf/0.1/>\n")
    expect(query.to_s).to include("<https://app.example.com/people/1> foaf:knows+ ?iri .")
    expect { algebra(query) }.not_to raise_error
  end

  it "renders a nil as FILTER NOT EXISTS" do
    query = described_class.new
    query.not_exists(ex.role)

    expect(query.to_s).to include("FILTER NOT EXISTS { ?iri ex:role ?o }")
    expect { algebra(query) }.not_to raise_error
  end

  it "renders a range as the README's FILTER" do
    query = described_class.new
    variable = query.bind(ex.age, "age")
    query.filter("?#{variable} >= 30 && ?#{variable} <= 40")

    expect(query.to_s).to include("?iri ex:age ?age .\n  FILTER(?age >= 30 && ?age <= 40)")
    expect { algebra(query) }.not_to raise_error
  end

  it "never reuses a bound variable name" do
    query = described_class.new
    expect(query.bind(ex.age, "age")).to eq("age")
    expect(query.bind(ex.age, "age")).to eq("age_1")
    expect(query.bind(ex.age, "iri")).to eq("iri_1")
  end

  it "refuses to write a name that is not a SPARQL variable" do
    query = described_class.new

    expect(query.bind(ex.role, "role; DROP")).to eq("v")
  end

  it "wraps the group in GRAPH when scoped to a named graph" do
    query = described_class.new(graph_name: "https://app.example.com/hr")
    query.equal(ex.role, RDF::Literal("engineer"))

    expect(query.to_s).to eq(<<~SPARQL)
      PREFIX ex: <https://app.example.com/ns#>
      SELECT DISTINCT ?iri
      WHERE {
        GRAPH <https://app.example.com/hr> {
          ?iri ex:role "engineer" .
        }
      }
    SPARQL
    expect { algebra(query) }.not_to raise_error
  end

  it "keeps LIMIT and OFFSET as fields, so a second one replaces the first" do
    query = described_class.new
    query.equal(ex.role, RDF::Literal("engineer"))

    once = query.dup.slice(limit: 5, offset: 10)
    twice = once.dup.slice(limit: 20)

    expect(once.to_s).to end_with("LIMIT 5\nOFFSET 10\n")
    expect(twice.to_s).to end_with("LIMIT 20\n")
    expect(twice.to_s.scan("LIMIT").size).to eq(1)
    expect { algebra(twice) }.not_to raise_error
  end

  it "orders by the subject when paging" do
    query = described_class.new
    query.equal(ex.role, RDF::Literal("engineer"))
    query.order_by_subject.slice(limit: 2, offset: 2)

    expect(query.to_s).to end_with("ORDER BY ?iri\nLIMIT 2\nOFFSET 2\n")
    expect { algebra(query) }.not_to raise_error
  end

  it "escapes a literal rather than letting it end the query" do
    query = described_class.new
    query.equal(ex.role, RDF::Literal(%(engineer" } INSERT DATA { <a> <b> "c)))

    expect(query.to_s).to include(%q(\" } INSERT DATA))
    expect(SPARQL.parse(query.to_s)).to be_a(SPARQL::Algebra::Operator)
  end

  it "does not share its lines with a copy" do
    query = described_class.new
    query.equal(ex.role, RDF::Literal("engineer"))
    copy = query.dup
    copy.equal(ex.role, RDF::Literal("manager"))

    expect(query.to_s).not_to include("manager")
    expect(copy.to_s).to include("engineer").and include("manager")
  end
end

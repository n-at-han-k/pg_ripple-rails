# frozen_string_literal: true

require "rails_helper"

# README, "Property paths". Every operator in the table, run against a real
# store through `Person.graph.via(path, from: …)` and joined back to rows.
#
# The unit specs already prove each operator renders the right SPARQL and that
# the `sparql` gem parses it to the right algebra. This file proves the other
# half: that spargebra — the Rust parser inside the extension, which is not the
# one the unit specs used — agrees, and that the solutions join back to
# records.
RSpec.describe "property paths" do
  # alice knows bob knows carol. alice manages bob and dave; bob manages carol.
  # alice and bob work at Acme, carol at Globex — the employers are plain IRIs
  # with no row behind them, which is what makes an inverse path testable.
  def fixture
    people = %w[alice bob carol dave].to_h do |name|
      [name.to_sym, Person.create!(name: name.capitalize)]
    end

    edges = [
      [people[:alice], foaf.knows, people[:bob]],
      [people[:bob], foaf.knows, people[:carol]],
      [people[:alice], ex.manages, people[:bob]],
      [people[:alice], ex.manages, people[:dave]],
      [people[:bob], ex.manages, people[:carol]]
    ]
    edges.each { |s, p, o| PgRipple.repository << RDF::Statement(s.rdf_subject, p.to_term, o.rdf_subject) }

    {alice: people[:alice], bob: people[:bob], carol: people[:carol], dave: people[:dave]}.each do |name, person|
      employer = (name == :carol) ? globex : acme
      PgRipple.repository << RDF::Statement(person.rdf_subject, ex.worksAt.to_term, employer)
    end

    people
  end

  def foaf = Person.foaf

  def ex = Person.ex

  def acme = RDF::URI("https://app.example.com/orgs/acme")

  def globex = RDF::URI("https://app.example.com/orgs/globex")

  def names_via(path, from:)
    relation = Person.graph.via(path, from: from)
    expect(relation.scope).to be_a(ActiveRecord::Relation)
    relation.order(:name).pluck(:name)
  end

  it "traverses a single predicate" do
    people = fixture

    expect(names_via(foaf.knows, from: people[:alice])).to eq(%w[Bob])
  end

  it "traverses a sequence" do
    people = fixture

    expect(names_via(foaf.knows / foaf.knows, from: people[:alice])).to eq(%w[Carol])
  end

  it "traverses an alternative" do
    people = fixture

    expect(names_via(foaf.knows | ex.manages, from: people[:alice])).to eq(%w[Bob Dave])
  end

  it "traverses one-or-more" do
    people = fixture

    expect(names_via(+foaf.knows, from: people[:alice])).to eq(%w[Bob Carol])
  end

  it "traverses zero-or-more, which includes the starting node" do
    people = fixture

    expect(names_via(foaf.knows.any, from: people[:alice])).to eq(%w[Alice Bob Carol])
  end

  it "traverses zero-or-one" do
    people = fixture

    expect(names_via(foaf.knows.opt, from: people[:alice])).to eq(%w[Alice Bob])
  end

  it "traverses an inverse" do
    people = fixture

    expect(names_via(~ex.manages, from: people[:bob])).to eq(%w[Alice])
  end

  it "traverses a negated property set" do
    people = fixture

    # Everything alice points at by some predicate other than foaf:knows, that
    # also has a row: her two reports. Her name, role, employer and rdf:type
    # are all objects of non-knows predicates too — they simply do not join.
    expect(names_via(!foaf.knows, from: people[:alice])).to eq(%w[Bob Dave])
  end

  it "traverses a sequence through an inverse" do
    people = fixture

    # Alice's colleagues: to the employer and back again.
    expect(names_via(ex.worksAt / ~ex.worksAt, from: people[:alice])).to eq(%w[Alice Bob Dave])
    expect(names_via(~ex.worksAt, from: acme)).to eq(%w[Alice Bob Dave])
  end

  it "reports the README's colleagues path as the empty relation it is" do
    people = fixture

    # `graph_has_many :colleagues, path: ~ex.worksAt / ex.worksAt` is the
    # README's spelling and the dummy model keeps it, because the README is the
    # acceptance criteria. It is inverted: read from a person, `^ex:worksAt`
    # asks who works at *Alice*, which is nobody. The path that means
    # "colleagues" is `ex.worksAt / ~ex.worksAt`, asserted above.
    expect(people[:alice].colleagues).to be_empty
    expect(people[:alice].colleagues.to_a).to eq([])
  end

  it "composes a path with SQL conditions and keeps the traversal a bind" do
    people = fixture
    people[:dave].update!(active: false)

    relation = Person.graph.via(!foaf.knows, from: people[:alice]).where(active: true)

    expect(relation.pluck(:name)).to eq(%w[Bob])
    expect(relation.to_sql).to include("JOIN LATERAL")
    expect(relation.to_sparql).to include("!(foaf:knows)")
  end
end

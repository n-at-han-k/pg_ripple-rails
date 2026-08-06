# frozen_string_literal: true

require "spec_helper"
require "rdf/vocab"

if DatabaseHelper.available?
  DatabaseHelper.connect!
  DatabaseHelper.execute(<<~SQL)
    DROP TABLE IF EXISTS relation_spec_people;
    DROP TABLE IF EXISTS relation_spec_accounts;
    CREATE TABLE relation_spec_accounts (id serial PRIMARY KEY, label text);
    CREATE TABLE relation_spec_people (
      id         serial PRIMARY KEY,
      account_id integer,
      name       text,
      email      text,
      active     boolean DEFAULT true,
      iri        text UNIQUE
    );
  SQL
end

RSpec.describe PgRipple::Relation, :database do
  let(:ex) { PgRipple::Path.vocabulary("https://app.example.com/ns#", prefix: "ex") }

  before do
    PgRipple.configure do |c|
      c.base_uri = "https://relation-spec.example.com/"
      c.default_graph = nil
    end
  end

  # A fresh anonymous pair per example: `graph` and `graph_has_many` generate
  # methods and constants, and a leaked one would make the suite
  # order-dependent.
  def models
    account = Class.new(ActiveRecord::Base) { self.table_name = "relation_spec_accounts" }
    stub_const("Account", account)

    person = Class.new(ActiveRecord::Base) do
      self.table_name = "relation_spec_people"
      include PgRipple::Node

      belongs_to :account, optional: true
    end
    stub_const("Person", person)

    vocab = ex
    person.graph(type: RDF::Vocab::FOAF.Person, iri: ->(p) { "people/#{p.id}" }) do
      property :name, predicate: RDF::Vocab::FOAF.name, from: :name
      property :email, predicate: RDF::Vocab::FOAF.mbox, from: :email,
        cast: ->(v) { RDF::URI("mailto:#{v}") }
      property :role, predicate: vocab.role.to_term
      property :years, predicate: vocab.years.to_term
    end

    [person, account]
  end

  # Alice engineer/35, Bob manager/41, Carol contractor/28 and inactive,
  # Dave engineer/33 with no role of his own is deliberately *not* here —
  # Erin has no role at all, which is what `where(role: nil)` is about.
  def fixture
    person, account = models
    acct = account.create!(label: "acme")

    people = {
      alice: person.create!(name: "Alice", email: "alice@example.com", account: acct, active: true),
      bob: person.create!(name: "Bob", account: acct, active: true),
      carol: person.create!(name: "Carol", account: acct, active: false),
      erin: person.create!(name: "Erin", account: acct, active: true)
    }

    {alice: ["engineer", 35], bob: ["manager", 41], carol: ["contractor", 28]}.each do |key, (role, years)|
      people[key].role = role
      people[key].years = years
      people[key].save!
    end
    people[:erin].years = 33
    people[:erin].save!

    [person, people]
  end

  describe "Model.graph" do
    it "is a builder, and any ActiveRecord method turns it into a relation" do
      person, = fixture

      expect(person.graph.where(role: "engineer")).to be_a(described_class)
      expect(person.graph.where(role: "engineer").order(:name)).to be_a(described_class)
      expect(person.graph.where(role: "engineer").scope).to be_a(ActiveRecord::Relation)
      expect(person.graph.where(role: "engineer").to_a.map(&:name)).to eq(["Alice"])
      expect(person.graph.where(role: "engineer").to_a.first).to be_a(person)
    end

    it "emits the README's SPARQL" do
      person, = fixture

      expect(person.graph.where(role: "engineer").to_sparql).to eq(<<~SPARQL)
        PREFIX ex: <https://app.example.com/ns#>
        SELECT DISTINCT ?iri
        WHERE {
          ?iri a <http://xmlns.com/foaf/0.1/Person> .
          ?iri ex:role "engineer" .
        }
      SPARQL
    end

    it "joins the traversal laterally, projecting out of the result JSONB" do
      person, = fixture
      sql = person.graph.where(role: "engineer").to_sql

      expect(sql).to include("JOIN LATERAL")
      expect(sql).to include("btrim(r.result ->> 'iri', '<>')")
      # A column definition list on a function with a declared composite return
      # type is a hard error, not a mismatch.
      expect(sql).not_to include("AS g(iri text)")
    end

    it "sends the SPARQL as a bind parameter, not as interpolated text" do
      person, = fixture
      statements = []
      subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        statements << payload
      end

      person.graph.where(role: "engineer'); DROP TABLE relation_spec_people; --").to_a

      ActiveSupport::Notifications.unsubscribe(subscription)
      executed = statements.reverse.find { |s| s[:sql].include?("pg_ripple.sparql") }

      expect(executed[:sql]).to include("pg_ripple.sparql($1::text)")
      expect(executed[:sql]).not_to include("DROP TABLE")
      expect(person.count).to eq(4)
    end
  end

  describe "#where" do
    it "matches a literal" do
      person, = fixture
      expect(person.graph.where(role: "engineer").pluck(:name)).to eq(["Alice"])
    end

    it "runs a value through the property's own cast" do
      person, = fixture
      expect(person.graph.where(email: "alice@example.com").pluck(:name)).to eq(["Alice"])
      expect(person.graph.where(email: "alice@example.com").to_sparql)
        .to include("<mailto:alice@example.com>")
    end

    it "reads nil as the absence of the property" do
      person, = fixture

      expect(person.graph.where(role: nil).pluck(:name)).to eq(["Erin"])
      expect(person.graph.where(role: nil).to_sparql).to include("FILTER NOT EXISTS")
    end

    it "reads a Range as a bounded FILTER" do
      person, = fixture

      expect(person.graph.where(years: 30..40).order(:name).pluck(:name)).to eq(%w[Alice Erin])
      # Typed, not bare: a graph value has RDF's typing and comparing it to a
      # bare `30` would be comparing an integer to a plain literal.
      integer = "http://www.w3.org/2001/XMLSchema#integer"
      expect(person.graph.where(years: 30..40).to_sparql)
        .to include(%(FILTER(?years >= "30"^^<#{integer}> && ?years <= "40"^^<#{integer}>)))
    end

    it "excludes the end of an exclusive Range" do
      person, = fixture

      expect(person.graph.where(years: 28...35).order(:name).pluck(:name)).to eq(%w[Carol Erin])
      expect(person.graph.where(years: 28..35).order(:name).pluck(:name)).to eq(%w[Alice Carol Erin])
    end

    it "reads a Regexp as REGEX, flags and all" do
      person, = fixture

      expect(person.graph.where(name: /^Al/).pluck(:name)).to eq(["Alice"])
      expect(person.graph.where(name: /^al/i).pluck(:name)).to eq(["Alice"])
      expect(person.graph.where(name: /^al/i).to_sparql).to include(%(REGEX(?name, "^al", "i")))
    end

    it "reads an Array as an IN filter" do
      person, = fixture

      expect(person.graph.where(role: %w[manager contractor]).order(:name).pluck(:name))
        .to eq(%w[Bob Carol])
    end

    it "hands a column straight to ActiveRecord" do
      person, = fixture
      relation = person.graph.where(role: "engineer", active: true)

      expect(relation.to_sparql).not_to include("active")
      expect(relation.to_sql).to include(%("relation_spec_people"."active"))
      expect(relation.pluck(:name)).to eq(["Alice"])
    end

    it "raises on a name that is neither a graph property nor a column" do
      person, = fixture

      expect { person.graph.where(rle: "engineer") }
        .to raise_error(PgRipple::UnknownProperty, /has no graph property or column :rle/)
    end
  end

  describe "#where.not" do
    # `FILTER(?role != "contractor")` would be satisfied by a subject who is a
    # contractor *and* something else, because a graph property is a set.
    it "is the absence of the triple, not an inequality" do
      person, = fixture

      expect(person.graph.where.not(role: "contractor").order(:name).pluck(:name))
        .to eq(%w[Alice Bob Erin])
      expect(person.graph.where.not(role: "contractor").to_sparql)
        .to include(%(FILTER NOT EXISTS { ?iri ex:role "contractor" }))
    end

    it "reads not-nil as the presence of the property" do
      person, = fixture

      expect(person.graph.where.not(role: nil).order(:name).pluck(:name)).to eq(%w[Alice Bob Carol])
    end

    it "hands a column straight to ActiveRecord" do
      person, = fixture

      expect(person.graph.where.not(active: true).pluck(:name)).to eq(["Carol"])
    end
  end

  describe "composing with ordinary scopes" do
    it "works from SQL into the graph" do
      person, = fixture

      expect(person.where(active: true).graph.where(role: "contractor").pluck(:name)).to eq([])
      expect(person.where(active: false).graph.where(role: "contractor").pluck(:name)).to eq(["Carol"])
    end

    it "works from the graph into SQL" do
      person, = fixture

      expect(person.graph.where(role: "contractor").where(active: false).pluck(:name)).to eq(["Carol"])
      expect(person.graph.where(role: nil).order(:name).limit(1).pluck(:name)).to eq(["Erin"])
    end
  end

  describe "#in_graph" do
    it "wraps the traversal in a GRAPH block" do
      person, = fixture
      sparql = person.graph.where(role: "engineer").in_graph("https://app.example.com/hr").to_sparql

      expect(sparql).to include("GRAPH <https://app.example.com/hr> {")
    end

    it "finds only what that graph holds" do
      person, people = fixture
      hr = PgRipple.repository(graph_name: "https://app.example.com/hr")
      hr.insert(
        RDF::Statement.new(
          RDF::URI(people[:erin].iri), RDF::Vocab::FOAF.name, RDF::Literal("Erin"),
          graph_name: RDF::URI("https://app.example.com/hr")
        )
      )

      in_hr = person.graph.in_graph("https://app.example.com/hr")
      expect(in_hr.where(name: "Erin").pluck(:name)).to eq([])
      expect(person.graph.where(name: "Erin").pluck(:name)).to eq(["Erin"])
    end
  end

  describe "#via" do
    it "traverses a path from a known subject" do
      person, people = fixture
      PgRipple.repository.insert(
        RDF::Statement.new(
          RDF::URI(people[:alice].iri), RDF::Vocab::FOAF.knows, RDF::URI(people[:bob].iri)
        )
      )

      expect(person.graph.via(RDF::Vocab::FOAF.knows, from: people[:alice]).pluck(:name)).to eq(["Bob"])
      expect(person.graph.via(RDF::Vocab::FOAF.knows, from: people[:alice].iri).pluck(:name)).to eq(["Bob"])
    end
  end

  describe "#to_sparql and LIMIT" do
    # `pg_ripple.sparql()` materialises every solution before PostgreSQL sees
    # row 1, so an outer LIMIT truncates work already done — 40x, measured.
    it "pushes a limit into the SPARQL when nothing downstream can drop a row" do
      person, = fixture

      expect(person.graph.where(role: "engineer").limit(1).to_sparql).to end_with("LIMIT 1\n")
      expect(person.graph.where(role: "engineer").limit(1).offset(2).to_sparql)
        .to end_with("LIMIT 1\nOFFSET 2\n")
    end

    it "does not push it down when a SQL predicate follows the join" do
      person, = fixture

      expect(person.graph.where(role: "engineer").where(active: true).limit(1).to_sparql)
        .not_to include("LIMIT")
      expect(person.graph.where(role: "engineer").order(:name).limit(1).to_sparql)
        .not_to include("LIMIT")
    end

    it "still returns the right rows either way" do
      person, = fixture

      expect(person.graph.where.not(role: nil).limit(2).count).to eq(2)
      expect(person.graph.where.not(role: nil).where(active: true).limit(2).order(:name).pluck(:name))
        .to eq(%w[Alice Bob])
    end

    # The OFFSET was applied twice: pushed into the SPARQL and left on the SQL.
    # `LIMIT` is idempotent so it hid, but every offset page came back empty —
    # 40 of 60 records unreachable, and nothing raised.
    it "takes the OFFSET off the SQL once it is in the SPARQL" do
      person, = fixture

      relation = person.graph.where.not(role: nil).limit(1).offset(1)

      expect(relation.to_sparql).to include("OFFSET 1")
      # The SPARQL travels inside the SQL, so only the SQL's own tail is
      # interesting: it ends at the LIMIT, with no OFFSET of its own.
      expect(relation.to_sql).to end_with("LIMIT 1")
      expect(relation.to_a.size).to eq(1)
    end

    it "pages a traversal without losing or repeating a subject" do
      person, = fixture

      pages = 3.times.map { |page| person.graph.where.not(role: nil).limit(1).offset(page).pluck(:name) }

      expect(pages.flatten.sort).to eq(%w[Alice Bob Carol])
    end

    # A SPARQL query with no ORDER BY has no defined solution order, so paging
    # it could visit a subject twice and another never. The bound is only
    # pushed down when the caller asked for no ordering of their own, so
    # `ORDER BY ?iri` is free to be the order.
    it "orders the query it pushes a bound into" do
      person, = fixture

      expect(person.graph.where(role: "engineer").limit(1).to_sparql).to include("ORDER BY ?iri")
      expect(person.graph.where(role: "engineer").to_sparql).not_to include("ORDER BY")
    end

    it "pushes down an offset with no limit at all" do
      person, = fixture

      relation = person.graph.where.not(role: nil).offset(2)

      expect(relation.to_sparql).to include("OFFSET 2")
      expect(relation.to_a.size).to eq(1)
    end
  end

  # Every graph association attaches to a fresh `target.all`, so an alias
  # counted from `joins_values.size` was `pg_ripple_graph_0` every time and
  # merging two traversals — ordinary ActiveRecord on two ordinary relations —
  # died with PG::DuplicateAlias. The alias is a digest of the SPARQL instead.
  describe "the lateral join alias" do
    it "differs between two independently built traversals" do
      person, = fixture

      merged = person.graph.where(role: "engineer").scope
        .merge(person.graph.where(role: "manager").scope)

      expect(merged.to_sql.scan(/AS pg_ripple_graph_\w+/).uniq.size).to eq(2)
      expect(merged.to_a).to eq([])
    end

    it "is the same for the same traversal, so the join deduplicates" do
      person, = fixture

      merged = person.graph.where(role: "engineer").scope
        .merge(person.graph.where(role: "engineer").scope)

      expect(merged.to_sql.scan(/AS pg_ripple_graph_\w+/).uniq.size).to eq(1)
      expect(merged.pluck(:name)).to eq(["Alice"])
    end
  end

  describe "#explain" do
    it "asks pg_ripple to explain the traversal, not PostgreSQL" do
      person, = fixture

      expect(person.graph.where(role: "engineer").explain).to be_a(String).and include("_pg_ripple")
      expect(person.graph.where(role: "engineer").explain_sql.inspect).to include("relation_spec_people")
    end
  end

  describe "#find_each" do
    it "streams through the cursor, paging in SPARQL" do
      person, = fixture
      names = []

      person.graph.where.not(role: nil).find_each(batch_size: 2) { |record| names << record.name }

      expect(names.sort).to eq(%w[Alice Bob Carol])
    end

    it "still applies the SQL conditions to every page" do
      person, = fixture
      names = []

      person.graph.where.not(role: nil).where(active: true)
        .find_each(batch_size: 1) { |record| names << record.name }

      expect(names.sort).to eq(%w[Alice Bob])
    end

    it "is an Enumerator without a block" do
      person, = fixture

      expect(person.graph.where(role: "engineer").find_each).to be_a(Enumerator)
    end
  end
end

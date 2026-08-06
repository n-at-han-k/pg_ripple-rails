# frozen_string_literal: true

require "rails_helper"

# README, "Preloading":
#
#     Person.where(role: "manager").graph_includes(:reports, :employer)
#
# The claim under test is not that the records come back — a lazy association
# returns the same records. It is that **no further query happens**, so every
# example that matters here counts queries. `expect(person.reports).to eq(...)`
# passes just as well without a preloader, which is why it is never the whole
# assertion below.
RSpec.describe "preloading" do
  # Every statement ActiveRecord actually sends, minus the ones that are not a
  # question about this gem: a cache hit sent nothing, `SCHEMA` is column
  # reflection, and the suite's own fixture transaction is not the subject.
  def statements
    sent = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      next if payload[:cached]
      next if %w[SCHEMA TRANSACTION].include?(payload[:name])

      sent << payload[:sql]
    end

    yield
    sent
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def query_count(&) = statements(&).length

  # alice -> bob -> carol by `ex:manages`, so `reports` (a `+` path) reaches
  # both from alice. Alice works at Acme; Erin is a manager with no reports and
  # no employer, which is the `OPTIONAL` that does not match. Dave is inactive,
  # so a SQL condition has something to remove.
  def fixture
    manages = Person.ex.manages.to_term
    works_at = Person.ex.worksAt.to_term

    acme = Organization.create!(name: "Acme")
    people = {
      alice: Person.create!(name: "Alice", role: "manager"),
      bob: Person.create!(name: "Bob", role: "engineer"),
      carol: Person.create!(name: "Carol", role: "engineer"),
      dave: Person.create!(name: "Dave", role: "engineer", active: false),
      erin: Person.create!(name: "Erin", role: "manager")
    }

    PgRipple.repository << RDF::Statement(people[:alice].rdf_subject, manages, people[:bob].rdf_subject)
    PgRipple.repository << RDF::Statement(people[:bob].rdf_subject, manages, people[:carol].rdf_subject)
    PgRipple.repository << RDF::Statement(people[:bob].rdf_subject, manages, people[:dave].rdf_subject)
    PgRipple.repository << RDF::Statement(people[:alice].rdf_subject, works_at, acme.rdf_subject)

    people.merge(acme: acme)
  end

  def managers
    Person.graph.where(role: "manager").order(:name)
  end

  it "runs the README's line in one round trip, and then queries nothing" do
    people = fixture

    sent = statements { @loaded = managers.graph_includes(:reports, :employer).to_a }

    # Four statements, and no more: the page itself, the one framed CONSTRUCT
    # for every association at once, and one row-load per *target class* —
    # `reports` lands on Person and `employer` on Organization.
    expect(sent.length).to eq(4)
    expect(sent.grep(/jsonld_frame/).length).to eq(1)
    expect(sent.grep(/FROM "people"/).length).to eq(2)
    expect(sent.grep(/FROM "organizations"/).length).to eq(1)

    expect(@loaded.map(&:name)).to eq(%w[Alice Erin])

    # Every reader, on every record of the page, for nothing.
    expect(query_count { @loaded.map { |person| [person.reports.to_a, person.employer] } }).to eq(0)

    expect(@loaded.first.reports.map(&:name)).to contain_exactly("Bob", "Carol", "Dave")
    expect(@loaded.first.employer).to eq(people[:acme])
    expect(@loaded.last.reports.to_a).to be_empty
    expect(@loaded.last.employer).to be_nil
  end

  it "is the difference between one query and N" do
    fixture

    lazy = query_count { Person.order(:name).to_a.each { |person| person.reports.to_a } }
    eager = query_count { Person.order(:name).graph_includes(:reports).to_a.each { |person| person.reports.to_a } }

    expect(lazy).to eq(6)   # the page, then one traversal per record
    expect(eager).to eq(3)  # the page, the CONSTRUCT, and one row-load
  end

  # A `+ex.manages` path cannot be a key in a frame — a frame nests properties,
  # and "one or more hops" is not a property. It is preloaded by projecting the
  # traversal onto a synthetic predicate in the CONSTRUCT template, so the path
  # is evaluated by SPARQL and the frame only ever sees something flat.
  # `docs/spec-corrections.md` §18.
  it "preloads a transitive path association, transitively" do
    people = fixture

    alice = Person.where(id: people[:alice].id).graph_includes(:reports).first

    expect(alice.graph_association_loaded?(:reports)).to be(true)
    expect(query_count { alice.reports.map(&:name) }).to eq(0)
    # Two hops away, which is what makes it the `+` path and not `ex:manages`.
    expect(alice.reports.map(&:name)).to contain_exactly("Bob", "Carol", "Dave")
  end

  it "preloads an inverse path into a graph_has_one" do
    people = fixture

    loaded = Person.where(id: [people[:bob].id, people[:alice].id]).order(:name).graph_includes(:manager).to_a

    expect(query_count { loaded.map(&:manager) }).to eq(0)
    expect(loaded.map { |person| person.manager&.name }).to eq([nil, "Alice"])
  end

  # With two or more roots the framed document is `{"@graph": [...]}`; with
  # exactly one it is the bare node object. A page of one is every
  # `find`-shaped preload, so both shapes are load-bearing.
  it "preloads a page of one" do
    people = fixture

    alice = Person.where(id: people[:alice].id).graph_includes(:reports, :employer).first

    expect(query_count { [alice.reports.to_a, alice.employer] }).to eq(0)
    expect(alice.employer.name).to eq("Acme")
  end

  # An `OPTIONAL` that did not match is an *absent key* — never null, never []
  # (`probe-jsonld-framing.md` §d). Hydration therefore drives off the
  # requested association list and not off the keys in the payload; if it did
  # the other thing, Erin would be left unloaded and would silently N+1.
  it "marks an association with no matches loaded and empty" do
    fixture

    erin = Person.where(name: "Erin").graph_includes(:reports, :employer).first

    expect(erin.graph_association_loaded?(:reports)).to be(true)
    expect(erin.graph_association_loaded?(:employer)).to be(true)
    expect(query_count { [erin.reports.to_a, erin.employer] }).to eq(0)
    expect(erin.reports.to_a).to eq([])
    expect(erin.employer).to be_nil
  end

  it "gives back a relation, not an array" do
    people = fixture

    alice = Person.where(id: people[:alice].id).graph_includes(:reports).first

    expect(alice.reports).to be_a(ActiveRecord::Relation)
    expect(alice.reports).to be_loaded
    # Narrowing a loaded relation queries again, exactly as it does on a
    # preloaded `has_many`.
    expect(alice.reports.where(active: true).map(&:name)).to contain_exactly("Bob", "Carol")
  end

  it "composes with ordinary includes, conditions and order" do
    fixture

    loaded = statements do
      @people = Person.where(active: true).includes(:account).order(:name).graph_includes(:reports).to_a
    end

    expect(@people.map(&:name)).to eq(%w[Alice Bob Carol Erin])
    expect(@people.first.association(:account)).to be_loaded
    expect(loaded.grep(/jsonld_frame/).length).to eq(1)
    expect(query_count { @people.flat_map { |person| person.reports.to_a } }).to eq(0)
  end

  it "composes with the lateral join, in either order" do
    fixture

    before_graph = Person.graph_includes(:reports).graph.where(role: "manager").order(:name)
    after_graph = Person.graph.where(role: "manager").graph_includes(:reports).order(:name)

    [before_graph, after_graph].each do |relation|
      loaded = relation.to_a

      expect(loaded.map(&:name)).to eq(%w[Alice Erin])
      expect(query_count { loaded.flat_map { |person| person.reports.to_a } }).to eq(0)
    end

    # `graph_includes` on `Person.graph` stays a PgRipple::Relation, so the
    # traversal is still there to be inspected and the `LIMIT` decision is
    # still the graph relation's to make.
    expect(after_graph).to be_a(PgRipple::Relation)
    expect(after_graph.to_sparql).to include("ex:role")
  end

  # `#merge` is how Rails composes named scopes, how a `has_many` `scope:`
  # block is applied, and how Ransack and ActiveAdmin build relations.
  # `ActiveRecord::SpawnMethods#merge` spawns the *receiver* and folds the
  # argument in through `Relation::Merger`, which knows nothing about this
  # gem's values — so the everyday `Person.where(...).merge(Person.with_reports)`
  # silently lost the preload and N+1'd, with nothing to see unless
  # `strict_loading` was on. `docs/spec-corrections.md` §22.
  it "survives a merge in either direction" do
    fixture

    receiver = Person.graph_includes(:reports).merge(Person.where(active: true)).order(:name)
    argument = Person.where(active: true).merge(Person.graph_includes(:reports)).order(:name)

    [receiver, argument].each do |relation|
      loaded = relation.to_a

      expect(loaded.map(&:name)).to eq(%w[Alice Bob Carol Erin])
      expect(query_count { loaded.flat_map { |person| person.reports.to_a } }).to eq(0)
    end
  end

  it "unions the includes of both sides of a merge" do
    fixture

    loaded = Person.graph_includes(:employer).merge(Person.graph_includes(:reports)).order(:name).to_a

    expect(query_count { loaded.map { |person| [person.reports.to_a, person.employer] } }).to eq(0)
  end

  it "survives a spawn after the fact" do
    fixture

    loaded = Person.graph_includes(:reports).where(active: true).order(:name).limit(2).to_a

    expect(loaded.map(&:name)).to eq(%w[Alice Bob])
    expect(query_count { loaded.flat_map { |person| person.reports.to_a } }).to eq(0)
  end

  it "invalidates the preloaded copy when the association is written through" do
    people = fixture

    alice = Person.where(id: people[:alice].id).graph_includes(:friends).first
    expect(alice.friends.to_a).to eq([])

    alice.friends << people[:erin]

    expect(alice.graph_association_loaded?(:friends)).to be(false)
    expect(alice.friends.map(&:name)).to eq(%w[Erin])
  end

  it "forgets the preload on reload" do
    people = fixture

    alice = Person.where(id: people[:alice].id).graph_includes(:reports).first
    alice.reload

    expect(alice.graph_association_loaded?(:reports)).to be(false)
  end

  # `graph_has_many …, graph_name: "https://…"`. The lazy read went through
  # PgRipple::Query, which coerces a String; the preload went through
  # PgRipple::Preloader.construct, which handed it straight to
  # PgRipple::Term.sparql and got `ArgumentError: "https://…" is not an
  # RDF::Term`. So the association read fine and *every load of the relation*
  # exploded. `docs/spec-corrections.md` §21.
  describe "a named-graph association" do
    let(:graph) { RDF::URI("https://app.example.com/graphs/hr") }

    def hr_fixture
      people = fixture
      repository = PgRipple.repository(graph_name: graph)
      repository << RDF::Statement(
        people[:alice].rdf_subject, Person.ex.manages.to_term, people[:erin].rdf_subject
      )
      people
    end

    it "reads the same records lazily and eagerly, with the graph as a String" do
      people = hr_fixture

      lazy = Person.find(people[:alice].id).hr_reports.map(&:name)
      eager = Person.where(id: people[:alice].id).graph_includes(:hr_reports).first

      # The named graph, and only the named graph: `reports` is the same path
      # in the default graph and reaches Bob, Carol and Dave instead.
      expect(lazy).to eq(%w[Erin])
      expect(query_count { eager.hr_reports.to_a }).to eq(0)
      expect(eager.hr_reports.map(&:name)).to eq(%w[Erin])
    end

    # The SPARQL travels as a bind, so it is not in the logged SQL — this is
    # the text that is bound.
    it "scopes the CONSTRUCT to that graph, in one round trip" do
      people = hr_fixture
      definition = Person.graph_associations.fetch(:hr_reports)

      sparql = PgRipple::Preloader.construct(
        [definition], [people[:alice].rdf_subject], graph_name: definition.graph_name
      )

      expect(sparql).to include("GRAPH <#{graph}>")
      expect(statements { Person.graph_includes(:hr_reports).to_a }.grep(/jsonld_frame/).length).to eq(1)
    end
  end

  # Neither path promises an order, and they do not agree on one — the lateral
  # returns the store's solution order and the preload returns the JSON-LD
  # reference order out of `jsonld_frame`. Both are stable run to run and
  # neither is defined, exactly as an unordered `has_many` is not defined in
  # ActiveRecord. What *is* promised is that an explicit order agrees, which is
  # the only form a caller should be relying on. `docs/spec-corrections.md` §23.
  it "agrees with the lazy read under an explicit order" do
    people = fixture

    lazy = Person.find(people[:alice].id).reports.order(:name).map(&:name)
    eager = Person.where(id: people[:alice].id).graph_includes(:reports).first
      .reports.order(:name).map(&:name)

    expect(lazy).to eq(%w[Bob Carol Dave])
    expect(eager).to eq(lazy)
  end

  it "names an association nothing declared, at the point of the call" do
    expect { Person.where(active: true).graph_includes(:sprockets) }
      .to raise_error(ArgumentError, /Person has no graph association :sprockets/)
  end

  describe "strict_loading" do
    before { PgRipple.configuration.strict_loading = true }

    it "raises rather than lazily querying" do
      people = fixture
      alice = Person.find(people[:alice].id)

      expect { alice.reports }.to raise_error(
        ActiveRecord::StrictLoadingViolationError, /Person#reports.*graph_includes\(:reports\)/m
      )
    end

    it "does not raise for a preloaded association" do
      people = fixture

      alice = Person.where(id: people[:alice].id).graph_includes(:reports).first

      expect(alice.reports.map(&:name)).to contain_exactly("Bob", "Carol", "Dave")
    end

    # The escape hatch stays open: `#<name>_relation` is the explicit "query
    # this one anyway", and a method whose only purpose is to run the query
    # cannot be the method that refuses to.
    it "leaves #<name>_relation alone" do
      people = fixture
      alice = Person.find(people[:alice].id)

      expect(alice.reports_relation.map(&:name)).to contain_exactly("Bob", "Carol", "Dave")
    end

    it "honours ActiveRecord's own per-record flag with the config off" do
      people = fixture
      PgRipple.configuration.strict_loading = false

      alice = Person.strict_loading.find(people[:alice].id)

      expect { alice.reports }.to raise_error(ActiveRecord::StrictLoadingViolationError)
      expect { Person.find(people[:alice].id).reports }.not_to raise_error
    end
  end
end

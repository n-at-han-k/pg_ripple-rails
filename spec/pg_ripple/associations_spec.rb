# frozen_string_literal: true

require "spec_helper"
require "rdf/vocab"

begin
  require "kaminari/activerecord"
rescue LoadError
  # The acceptance example skips rather than fails: Kaminari is a Gemfile
  # entry, not a dependency of the gem.
  nil
end

if DatabaseHelper.available?
  DatabaseHelper.connect!
  DatabaseHelper.execute(<<~SQL)
    DROP TABLE IF EXISTS association_spec_people;
    DROP TABLE IF EXISTS association_spec_accounts;
    CREATE TABLE association_spec_accounts (id serial PRIMARY KEY, label text);
    CREATE TABLE association_spec_people (
      id         serial PRIMARY KEY,
      account_id integer,
      name       text,
      active     boolean DEFAULT true,
      iri        text UNIQUE
    );
  SQL
end

RSpec.describe PgRipple::Associations, :database do
  let(:foaf) { PgRipple::Path.vocabulary("http://xmlns.com/foaf/0.1/", prefix: "foaf") }
  let(:ex) { PgRipple::Path.vocabulary("https://app.example.com/ns#", prefix: "ex") }

  before do
    PgRipple.configure do |c|
      c.base_uri = "https://association-spec.example.com/"
      c.default_graph = nil
    end
  end

  def models
    account = Class.new(ActiveRecord::Base) { self.table_name = "association_spec_accounts" }
    stub_const("Account", account)

    knows = foaf.knows
    manages = ex.manages
    works_at = ex.worksAt

    person = Class.new(ActiveRecord::Base) do
      self.table_name = "association_spec_people"
      include PgRipple::Node

      belongs_to :account, optional: true

      graph type: RDF::Vocab::FOAF.Person, iri: ->(p) { "people/#{p.id}" } do
        property :name, predicate: RDF::Vocab::FOAF.name, from: :name
      end

      graph_has_many :friends, predicate: knows, class_name: "Person"
      graph_has_many :network, path: +knows, class_name: "Person"
      graph_has_many :reports, path: +manages, class_name: "Person"
      graph_has_one :manager, path: ~manages, class_name: "Person"
      graph_has_many :colleagues, path: ~works_at / works_at, class_name: "Person"
    end
    stub_const("Person", person)

    [person, account]
  end

  # alice -> bob -> carol -> dave -> erin, plus alice -> erin. Dave is
  # inactive, which is what the SQL half of every example filters on.
  def fixture
    person, account = models
    acct = account.create!(label: "acme")

    names = %w[alice bob carol dave erin]
    people = names.to_h do |name|
      [name.to_sym, person.create!(name: name.capitalize, account: acct, active: name != "dave")]
    end

    people[:alice].friends << [people[:bob], people[:erin]]
    people[:bob].friends << people[:carol]
    people[:carol].friends << people[:dave]
    people[:dave].friends << people[:erin]

    [person, people]
  end

  describe "graph_has_many" do
    it "returns a real ActiveRecord::Relation" do
      _, people = fixture
      friends = people[:alice].friends

      expect(friends).to be_a(ActiveRecord::Relation)
      expect(friends.order(:name).pluck(:name)).to eq(%w[Bob Erin])
      expect(friends.first).to be_a(Person)
    end

    it "traverses a transitive path" do
      _, people = fixture

      expect(people[:alice].network.order(:name).pluck(:name)).to eq(%w[Bob Carol Dave Erin])
    end

    it "composes with ordinary ActiveRecord" do
      _, people = fixture

      expect(people[:alice].network.where(active: true).order(:name).limit(20).pluck(:name))
        .to eq(%w[Bob Carol Erin])
      expect(people[:alice].network.count).to eq(4)
      expect(people[:alice].network.where(active: false).pluck(:name)).to eq(["Dave"])
    end

    it "emits the corrected lateral join" do
      _, people = fixture
      sql = people[:alice].network.where(active: true).to_sql

      expect(sql).to include("JOIN LATERAL")
      expect(sql).to include("btrim(r.result ->> 'iri', '<>')")
      expect(sql).to include("foaf:knows+")
      expect(sql).to include(%("association_spec_people"."active" = TRUE))
    end

    it "binds the subject at build time, so the lateral is uncorrelated" do
      _, people = fixture
      sql = people[:alice].network.to_sql

      # The subject is a constant in the SPARQL, not a reference to an outer
      # column: a correlated lateral is one full parse-plan-execute per row.
      expect(sql).to include("<#{people[:alice].iri}> foaf:knows+ ?iri")
      expect(sql).not_to include("format(")
    end

    it "defaults the target class to the association name" do
      person, = models
      expect(person.graph_associations[:network].target).to eq(person)
    end

    it "refuses both predicate: and path:" do
      person, = models

      expect { person.graph_has_many(:bad, predicate: foaf.knows, path: +foaf.knows) }
        .to raise_error(ArgumentError, /exactly one of/)
      expect { person.graph_has_many(:bad) }.to raise_error(ArgumentError, /exactly one of/)
    end

    it "needs a saved record" do
      person, = models

      expect { person.new.friends }.to raise_error(PgRipple::IriError, /saved record/)
    end
  end

  # Every other entry point in the gem takes a graph as a String, so this one
  # has to as well — and it has to hand the *same object* to both readers, or
  # the lazy path (which coerces, through PgRipple::Query) and the preload
  # path (which does not, and raised) disagree about what a graph is.
  # `docs/spec-corrections.md` §21.
  describe "Definition#graph_name" do
    def definition(graph_name)
      PgRipple::Associations::Definition.new(
        :reports, owner: nil, path: +ex.manages, class_name: "Person", graph_name: graph_name
      )
    end

    it "coerces a String to an RDF::URI" do
      expect(definition("https://app.example.com/hr").graph_name)
        .to eq(RDF::URI("https://app.example.com/hr"))
    end

    it "strips the angle brackets an N-Triples IRI wears" do
      expect(definition("<https://app.example.com/hr>").graph_name)
        .to eq(RDF::URI("https://app.example.com/hr"))
    end

    it "leaves the default graph as nil" do
      expect(definition(nil).graph_name).to be_nil
    end

    it "coerces the configured default the same way" do
      PgRipple.configuration.default_graph = "https://app.example.com/main"

      expect(
        PgRipple::Associations::Definition.new(
          :reports, owner: nil, path: +ex.manages, class_name: "Person"
        ).graph_name
      ).to eq(RDF::URI("https://app.example.com/main"))
    ensure
      PgRipple.configuration.default_graph = nil
    end

    # What PgRipple::Preloader groups on to decide how many CONSTRUCTs to run.
    # A String and an equal RDF::URI are different Hash keys, so without the
    # coercion two associations naming one graph two ways were two round trips.
    it "is one group key however the graph was written" do
      keys = [definition("https://app.example.com/hr"), definition(RDF::URI("https://app.example.com/hr"))]

      expect(keys.group_by(&:graph_name).size).to eq(1)
    end
  end

  describe "graph_has_one" do
    it "returns the record, and the relation is next door" do
      _, people = fixture
      people[:bob].reports_relation # no-op, just proves the reader exists

      PgRipple.repository.insert(
        RDF::Statement.new(
          RDF::URI(people[:bob].iri),
          RDF::URI("https://app.example.com/ns#manages"),
          RDF::URI(people[:carol].iri)
        )
      )

      expect(people[:carol].manager).to be_a(Person)
      expect(people[:carol].manager.name).to eq("Bob")
      expect(people[:carol].manager_relation).to be_a(ActiveRecord::Relation)
      expect(people[:bob].reports.pluck(:name)).to eq(["Carol"])
      expect(people[:alice].manager).to be_nil
    end

    it "reads an inverse path as the other direction of the same edge" do
      person, = models

      expect(person.graph_associations[:manager].path.to_s).to eq("^ex:manages")
      expect(person.graph_associations[:colleagues].path.to_s).to eq("^ex:worksAt/ex:worksAt")
    end
  end

  describe "#<< and #delete" do
    it "emits INSERT DATA and DELETE DATA" do
      _, people = fixture
      updates = []
      allow(PgRipple.repository).to receive(:sparql_update).and_wrap_original do |original, text|
        updates << text
        original.call(text)
      end

      people[:carol].friends << people[:alice]
      expect(updates.last).to include("INSERT DATA {").and include(
        "<#{people[:carol].iri}> <http://xmlns.com/foaf/0.1/knows> <#{people[:alice].iri}> ."
      )
      expect(people[:carol].friends.pluck(:name)).to include("Alice")

      people[:carol].friends.delete(people[:alice])
      expect(updates.last).to include("DELETE DATA {")
      expect(people[:carol].friends.pluck(:name)).not_to include("Alice")
    end

    it "publishes the write, so change_triples can see it" do
      _, people = fixture
      writes = []
      subscription = ActiveSupport::Notifications.subscribe(PgRipple::Persistence::WRITE) do |*, payload|
        writes << payload
      end

      people[:carol].friends << people[:alice]

      ActiveSupport::Notifications.unsubscribe(subscription)
      expect(writes.size).to eq(1)
      expect(writes.first[:inserted_count]).to eq(1)
      expect(writes.first[:inserted].first.predicate).to eq(RDF::Vocab::FOAF.knows)
    end

    it "rolls back with the surrounding transaction" do
      _, people = fixture

      Person.transaction(requires_new: true) do
        people[:carol].friends << people[:alice]
        expect(people[:carol].friends.pluck(:name)).to include("Alice")
        raise ActiveRecord::Rollback
      end

      expect(people[:carol].friends.pluck(:name)).not_to include("Alice")
    end

    it "refuses a path that is not a single predicate" do
      _, people = fixture

      expect { people[:alice].network << people[:carol] }
        .to raise_error(PgRipple::NotAPredicate, /property path, not a single predicate/)
    end

    it "refuses a record of the wrong class" do
      _, people = fixture
      account = Account.create!(label: "other")

      expect { people[:alice].friends << account }.to raise_error(ArgumentError, /holds Person/)
    end

    it "survives a spawn, and refuses to write through a filtered one" do
      _, people = fixture
      filtered = people[:alice].friends.where(active: true)

      expect(filtered).to respond_to(:<<)
      expect(filtered.pg_ripple_owner).to eq(people[:alice])
    end

    # `#create!` used to be the plain relation's: it inserted a row, wrote no
    # triple, and returned a record the association did not contain.
    it "links what #create! creates" do
      _, people = fixture

      created = people[:erin].friends.create!(name: "Frank")

      expect(created).to be_persisted
      expect(people[:erin].friends.pluck(:name)).to eq(["Frank"])
    end

    it "links every record a #create! of many creates" do
      _, people = fixture

      people[:erin].friends.create!([{name: "Frank"}, {name: "Grace"}])

      expect(people[:erin].friends.order(:name).pluck(:name)).to eq(%w[Frank Grace])
    end

    it "leaves a #create that failed validation unlinked" do
      _, people = fixture
      Person.validates :name, presence: true

      created = people[:erin].friends.create(name: nil)

      expect(created).not_to be_persisted
      expect(people[:erin].friends).to be_empty
    end

    # A graph edge is a triple between two subject IRIs, and an unsaved record
    # has none. `#build` used to hand back an unlinked record instead.
    it "refuses to build an unsaved record" do
      _, people = fixture

      expect { people[:alice].friends.build(name: "Frank") }
        .to raise_error(NotImplementedError, /cannot build an unsaved record/)
      expect { people[:alice].friends.new(name: "Frank") }
        .to raise_error(NotImplementedError, /cannot build an unsaved record/)
    end
  end

  # Two association relations both attached to a fresh `target.all`, so an
  # alias counted from `joins_values.size` was `pg_ripple_graph_0` in both and
  # merging them raised PG::DuplicateAlias.
  describe "merging two graph associations" do
    it "gives each traversal its own lateral alias" do
      _, people = fixture

      merged = people[:alice].friends.merge(people[:alice].network)

      expect(merged.to_sql.scan(/AS pg_ripple_graph_\w+/).uniq.size).to eq(2)
      expect(merged.order(:name).pluck(:name)).to eq(%w[Bob Erin])
    end

    # Alice knows Bob and Erin, Bob knows Carol: the intersection is empty, and
    # an empty result is the *right* answer rather than the raised one.
    it "merges two owners' associations" do
      _, people = fixture

      merged = people[:alice].friends.merge(people[:bob].friends)

      expect(merged.to_sql.scan(/AS pg_ripple_graph_\w+/).uniq.size).to eq(2)
      expect(merged.pluck(:name)).to eq([])
    end
  end

  describe "the README's acceptance line" do
    it "is an ActiveRecord::Relation that Kaminari paginates" do
      skip "kaminari is not installed" unless defined?(Kaminari)
      _, people = fixture

      relation = people[:alice].network.where(active: true).includes(:account).page(2).per(2)

      expect(relation).to be_a(ActiveRecord::Relation)
      expect(relation.map(&:name)).to eq(["Erin"])
      expect(relation.total_count).to eq(3)
      expect(relation.current_page).to eq(2)
      # `includes` loads the association without a second query per record.
      expect(relation.first.association(:account)).to be_loaded
    end
  end
end

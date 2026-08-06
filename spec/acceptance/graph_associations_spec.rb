# frozen_string_literal: true

require "rails_helper"

begin
  require "kaminari/activerecord"
rescue LoadError
  # Kaminari is a Gemfile entry, not a dependency of the gem. The pagination
  # example skips rather than fails when it is absent.
  nil
end

# README, "Graph associations":
#
#     alice.network.where(active: true).order(:name).limit(20)
#
# The claim under test is not that a traversal returns records — it is that
# what comes back is an `ActiveRecord::Relation`, with everything that implies:
# it composes with SQL conditions, it eager-loads, and a pagination gem that
# has never heard of RDF can page it.
RSpec.describe "graph associations" do
  # alice -> bob -> carol -> dave -> erin, plus alice -> erin.
  # Dave is inactive: he is what the SQL half of every chain filters out, and
  # his position in the middle of the path is what proves the filter happens
  # after the traversal rather than instead of it.
  def fixture
    account = Account.create!(name: "Acme")

    people = %w[alice bob carol dave erin].to_h do |name|
      [name.to_sym, Person.create!(name: name.capitalize, account: account, active: name != "dave")]
    end

    people[:alice].friends << [people[:bob], people[:erin]]
    people[:bob].friends << people[:carol]
    people[:carol].friends << people[:dave]
    people[:dave].friends << people[:erin]

    people
  end

  it "returns an ActiveRecord::Relation" do
    people = fixture

    expect(people[:alice].friends).to be_a(ActiveRecord::Relation)
    expect(people[:alice].friends.order(:name).pluck(:name)).to eq(%w[Bob Erin])
    expect(people[:alice].friends.first).to be_a(Person)
  end

  it "runs the README's chain" do
    people = fixture

    expect(people[:alice].network.where(active: true).order(:name).limit(20).pluck(:name))
      .to eq(%w[Bob Carol Erin])
  end

  it "composes with the rest of ActiveRecord" do
    people = fixture

    expect(people[:alice].network.count).to eq(4)
    expect(people[:alice].reports).to be_empty
    expect(people[:alice].network.where(active: false).pluck(:name)).to eq(%w[Dave])
    expect(people[:alice].network.includes(:account).first.association(:account)).to be_loaded
  end

  it "paginates" do
    skip "kaminari is not installed" unless Person.respond_to?(:page)
    people = fixture

    page = people[:alice].network.where(active: true).includes(:account).order(:name).page(2).per(2)

    expect(page).to be_a(ActiveRecord::Relation)
    expect(page.pluck(:name)).to eq(%w[Erin])
    expect(page.total_count).to eq(3)
    expect(page.current_page).to eq(2)
  end

  it "writes through the association and reads back as models" do
    people = fixture

    expect { people[:erin].friends << people[:alice] }
      .to change_triples(inserting: 1, deleting: 0)
    expect(people[:erin]).to have_triple(RDF::Vocab::FOAF.knows, people[:alice].rdf_subject)
    expect(people[:erin].friends.pluck(:name)).to eq(%w[Alice])

    expect { people[:erin].friends.delete(people[:alice]) }
      .to change_triples(inserting: 0, deleting: 1)
    expect(people[:erin].friends).to be_empty
  end

  it "resolves graph_has_one to a record" do
    people = fixture

    # Not `people[:alice].reports << people[:bob]`: `reports` is a `+ex.manages`
    # path and there is no single triple that means "one or more hops", so `<<`
    # on it raises. The edge itself is what the association reads.
    PgRipple.repository <<
      RDF::Statement(people[:alice].rdf_subject, Person.ex.manages.to_term, people[:bob].rdf_subject)

    expect(people[:bob].manager).to eq(people[:alice])
    expect(people[:bob].manager_relation).to be_a(ActiveRecord::Relation)
  end
end

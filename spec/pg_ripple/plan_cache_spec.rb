# frozen_string_literal: true

require "spec_helper"
require "securerandom"

# pg_ripple 0.128.0 does not invalidate its per-backend SPARQL plan cache when
# a transaction aborts. The generated SQL embeds the dictionary ids of the
# query's constants as integer literals; `ROLLBACK` deletes those dictionary
# rows, and the next execution of the same query text is a cache hit against
# ids that no longer exist, so it returns **zero rows** — silently, for the
# life of that backend. `docs/probe-cache-invalidation.md` has the
# discrimination that rules out the dictionary caches, `DISCARD ALL`,
# `flush_encode_cache()` and the `plan_cache_size = 0` GUC.
#
# This is the extension's bug. The gem's job is to make it survivable, and
# these examples are the measurement: three rounds of insert-then-read, each in
# its own rolled-back transaction, on one connection.
#
# `:no_transaction`, because the hazard is a *top-level* rollback — see
# `spec/support/database.rb`. Nothing here commits.
RSpec.describe PgRipple::PlanCache, :database, :no_transaction do
  let(:repository) { PgRipple.repository }

  # A term nothing else has minted: the cache is keyed on the query text, so a
  # shared IRI would make one example's poisoning another example's problem.
  let(:iri) { RDF::URI("https://plan-cache.test/#{SecureRandom.hex(6)}") }
  let(:predicate) { RDF::URI("https://plan-cache.test/role") }

  # One round: write a triple, read it back with SPARQL, throw the transaction
  # away.
  #
  # SPARQL rather than `repository.query([iri, predicate, nil])`, and that is
  # worth knowing: a single triple pattern is answered by
  # `pg_ripple.find_triples()`, which takes its terms as arguments, has no
  # compiled plan and so cannot be poisoned. What the plan cache holds is
  # *parsed SPARQL* — `#sparql`, `#ask`, a multi-pattern BGP through
  # `#query_execute`, and every property-path traversal behind
  # `graph_has_many`. Those are the exposed reads.
  def round
    count = nil

    ActiveRecord::Base.transaction do
      repository << [iri, predicate, "engineer"]
      count = repository.sparql("SELECT ?o WHERE { #{iri.to_base} #{predicate.to_base} ?o }").count

      raise ActiveRecord::Rollback
    end

    count
  end

  around do |example|
    hook = PgRipple.configuration.reset_plan_cache_on_rollback
    graph = PgRipple.configuration.default_graph
    PgRipple.configure { |c| c.default_graph = nil }

    example.run
  ensure
    PgRipple.configure do |c|
      c.reset_plan_cache_on_rollback = hook
      c.default_graph = graph
    end
  end

  context "with the invalidation hook off" do
    before { PgRipple.configuration.reset_plan_cache_on_rollback = false }

    # The bug, reproduced through the gem rather than in psql. If this ever
    # reads [1, 1, 1], the extension has been fixed and the hook can go.
    it "reads nothing after the first rolled-back transaction" do
      expect(Array.new(3) { round }).to eq([1, 0, 0])
    end

    it "is repaired by PgRipple.reset_plan_cache!" do
      counts = Array.new(3) do
        PgRipple.reset_plan_cache!
        round
      end

      expect(counts).to eq([1, 1, 1])
    end
  end

  context "with the invalidation hook on, as it is by default" do
    before { PgRipple.configuration.reset_plan_cache_on_rollback = true }

    it "reads correctly after every rolled-back transaction" do
      expect(Array.new(3) { round }).to eq([1, 1, 1])
    end

    it "marks the connection on rollback and resets on the next statement" do
      round

      ActiveRecord::Base.with_connection do |connection|
        expect(described_class.poisoned?(connection)).to be(true)
      end

      repository.sparql("SELECT ?s WHERE { ?s ?p ?o } LIMIT 1")

      ActiveRecord::Base.with_connection do |connection|
        expect(described_class.poisoned?(connection)).to be(false)
      end
    end
  end

  # What a host application's spec suite looks like when the rollback hook
  # cannot help it: it cleans with `TRUNCATE` or DatabaseCleaner, or it reaches
  # the store through SQL that never passes through this gem, so nothing marks
  # the connection. README "Testing" tells such a suite to
  # `config.include PgRipple::TestHelpers` and call the helper from its own
  # `before(:each)`. This is that arrangement, run.
  context "a suite that resets the cache itself" do
    before { PgRipple.configuration.reset_plan_cache_on_rollback = false }

    # Exactly what `RSpec.configure { |c| c.include PgRipple::TestHelpers }`
    # hands an example group: the module, mixed into the example's own class.
    let(:host_app_example) { Class.new { include PgRipple::TestHelpers }.new }

    it "reads correctly in every round" do
      counts = Array.new(3) do
        host_app_example.ripple_reset_plan_cache! # the host suite's before(:each)
        round
      end

      expect(counts).to eq([1, 1, 1])
    end

    # The same suite written against the published-but-wrong name still works,
    # and says so. It is a one-release alias, not a second mechanism.
    it "still works through the deprecated spelling, with a warning" do
      allow(host_app_example).to receive(:warn)
      allow(PgRipple::TestHelpers).to receive(:warn)

      counts = Array.new(3) do
        host_app_example.ripple_reset_dictionary_cache!
        round
      end

      expect(counts).to eq([1, 1, 1])
      expect(PgRipple::TestHelpers).to have_received(:warn).with(/deprecated/).at_least(:once)
    end
  end

  describe ".poison!" do
    # The guard that makes the reset safe to issue without first asking whether
    # the extension is installed: a connection this gem has never run a
    # statement on is never marked, so it is never reset.
    it "leaves a connection this gem has never spoken to alone" do
      connection = Object.new

      described_class.poison!(connection)

      expect(described_class.poisoned?(connection)).to be(false)
    end
  end
end

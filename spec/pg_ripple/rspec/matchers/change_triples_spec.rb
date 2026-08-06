# frozen_string_literal: true

require "spec_helper"
require "pg_ripple/rspec"

RSpec.describe PgRipple::RSpec::Matchers::ChangeTriples do
  let(:ex) { RDF::Vocabulary.new("https://app.example.com/ns#") }
  let(:alice) { RDF::URI("https://app.example.com/people/1") }

  # No database: the matcher watches the write event, so a spec for the matcher
  # only has to publish one. That is the point of the design — a before/after
  # count could not tell a diff from a whole-object rewrite, because both leave
  # the store identical.
  def write(deleted: [], inserted: [])
    PgRipple::Persistence.notify(deleted: deleted, inserted: inserted)
  end

  def triple(predicate, object)
    RDF::Statement.new(alice, predicate, RDF::Literal(object))
  end

  it "counts a replaced value as one fact changed, which is the README's by: 1" do
    expect {
      write(deleted: [triple(ex.role, "engineer")], inserted: [triple(ex.role, "manager")])
    }.to change_triples(by: 1)
  end

  it "reports the raw triple counts too" do
    expect {
      write(deleted: [triple(ex.role, "engineer")], inserted: [triple(ex.role, "manager")])
    }.to change_triples(inserting: 1, deleting: 1)
  end

  it "fails when a whole-object rewrite moves more facts than expected" do
    rewrite = lambda do
      statements = [triple(ex.role, "manager"), triple(ex.name, "Alice"), triple(ex.nick, "Al")]
      write(deleted: statements, inserted: statements)
    end

    expect { expect(&rewrite).to change_triples(by: 1) }
      .to raise_error(::RSpec::Expectations::ExpectationNotMetError, /changed 3 fact/)
  end

  it "passes bare when anything at all was written" do
    expect { write(inserted: [triple(ex.role, "manager")]) }.to change_triples
  end

  it "is satisfied negatively by a block that writes nothing" do
    expect { 1 + 1 }.not_to change_triples
  end

  it "refuses a negated count, which would say almost nothing" do
    expect { expect { write(inserted: [triple(ex.role, "x")]) }.not_to change_triples(by: 2) }
      .to raise_error(ArgumentError, /no arguments/)
  end

  it "counts a DELETE WHERE by the number the server reported" do
    expect { PgRipple::Persistence.notify(deleted_count: 4) }.to change_triples(by: 4)
  end

  it "unsubscribes even when the block raises" do
    expect { expect { raise "boom" }.to change_triples }.to raise_error("boom")

    matcher = change_triples
    expect { matcher.matches?(-> {}) }.not_to raise_error
    expect(matcher.writes).to be_empty
  end

  it "names the triples it saw when it fails" do
    matcher = change_triples(by: 2)
    matcher.matches?(-> { write(inserted: [triple(ex.role, "manager")]) })

    expect(matcher.failure_message).to include("+ <https://app.example.com/people/1>")
  end
end

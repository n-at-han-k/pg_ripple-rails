# frozen_string_literal: true

# The README's "Models" section, as an actual model.
#
# Two deliberate differences from the printed code, both settled by earlier
# phases and recorded in `docs/spec-corrections.md`:
#
# * `cast:` for `email` is the callable form. The README's `cast: RDF::URI`
#   cannot produce the `<mailto:alice@example.com>` its own Turtle shows —
#   `RDF::URI("alice@example.com")` is a relative reference whose `#valid?` is
#   false — so the callable is what makes the documented output real.
# * `graph` is called twice. It is additive, which is what lets the README
#   introduce `dependent: :nullify_references` in a later section as its own
#   line rather than as an edit to the first one.
class Person < ApplicationRecord
  include PgRipple::Node

  belongs_to :account, optional: true

  graph type: RDF::Vocab::FOAF.Person, iri: ->(p) { "people/#{p.id}" } do
    property :name, predicate: RDF::Vocab::FOAF.name, from: :name
    property :email, predicate: RDF::Vocab::FOAF.mbox, from: :email,
      cast: ->(v) { RDF::URI("mailto:#{v}") }
    property :birthdate, predicate: RDF::Vocab::FOAF.birthday, from: :born_on
    property :role, predicate: EX.role # graph-only, no column
  end

  graph dependent: :nullify_references # also DELETE WHERE { ?s ?p <iri> }

  graph_has_many :friends, predicate: foaf.knows, class_name: "Person"
  graph_has_many :network, path: +foaf.knows, class_name: "Person"
  graph_has_many :reports, path: +ex.manages, class_name: "Person"
  graph_has_one :manager, path: ~ex.manages, class_name: "Person"
  graph_has_many :colleagues, path: ~ex.worksAt / ex.worksAt, class_name: "Person"
  graph_has_one :employer, predicate: ex.worksAt, class_name: "Organization"

  # The same traversal, scoped to a named graph, with the graph written as a
  # `String` — the form `PgRipple.repository(graph_name:)`,
  # `PgRipple::Query.new` and the README's `c.default_graph` all take. Here
  # because `graph_includes` used to raise `ArgumentError` for exactly this
  # while the lazy read worked (`docs/spec-corrections.md` §21).
  graph_has_many :hr_reports, path: +ex.manages, class_name: "Person",
    graph_name: "https://app.example.com/graphs/hr"
end

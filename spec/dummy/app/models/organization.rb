# frozen_string_literal: true

# The far end of `Person#employer`.
#
# Here so the README's `Person.where(role: "manager").graph_includes(:reports,
# :employer)` is real: `reports` lands on `Person` and `employer` on this, so
# one preload has to load two target classes and must not confuse their IRIs.
class Organization < ApplicationRecord
  include PgRipple::Node

  # `.to_term` because `ex.Organization` is a {PgRipple::Path} and `graph
  # type:` wants the term: `RDF::URI.intern` of the path would intern the
  # *CURIE* `ex:Organization`.
  graph type: ex.Organization.to_term, iri: ->(o) { "organizations/#{o.id}" } do
    property :name, predicate: RDF::Vocab::FOAF.name, from: :name
  end

  graph_has_many :staff, path: ~ex.worksAt, class_name: "Person"
end

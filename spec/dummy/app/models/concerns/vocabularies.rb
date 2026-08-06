# frozen_string_literal: true

require "rdf/vocab"

# The lower-case `foaf` and `ex` the README's "Graph associations" section uses
# in a class body — `graph_has_many :friends, predicate: foaf.knows`.
#
# They are {PgRipple::Path::Vocabulary} objects, not `RDF::Vocabulary`: a path
# has to be able to answer `+foaf.knows` and `~ex.manages`, which a plain term
# cannot. Extended into the singleton of `ApplicationRecord` so every model
# class body can say them; a host app is free to put them anywhere.
module Vocabularies
  FOAF = PgRipple::Path.vocabulary(RDF::Vocab::FOAF, prefix: :foaf)
  EX = PgRipple::Path.vocabulary("https://app.example.com/ns#", prefix: :ex)

  # @return [PgRipple::Path::Vocabulary]
  def foaf = FOAF

  # @return [PgRipple::Path::Vocabulary]
  def ex = EX
end

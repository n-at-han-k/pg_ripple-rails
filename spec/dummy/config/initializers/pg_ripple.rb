# frozen_string_literal: true

require "rdf/vocab"

# The application vocabulary the README's "Models" section writes as `EX.role`.
#
# Guarded because `spec/pg_ripple/node_spec.rb` — which runs without Rails and
# therefore without this initializer — defines the same constant at the same
# IRI. Whichever loads first wins and the other is a no-op, rather than a
# redefinition warning on every run.
EX = RDF::Vocabulary.new("https://app.example.com/ns#") unless defined?(EX)

PgRipple.configure do |c|
  c.base_uri = "https://app.example.com/"
  c.default_graph = nil # nil = default graph
  c.validate = :sync    # :sync | :async | :off
  c.strict_loading = Rails.env.local?
end

# frozen_string_literal: true

require "active_record"
require "rdf"

module PgRipple
  # Small conveniences for a suite that asserts about the graph.
  #
  #     RSpec.configure { |c| c.include PgRipple::TestHelpers }
  #
  # Triples roll back with the transactional fixture, because they are written
  # on the same connection inside the same transaction
  # (`docs/probe-lateral-join.md` §e). So there is nothing to *truncate*, and a
  # suite that clears the store between examples is working around a problem it
  # does not have — `DROP EXTENSION pg_ripple CASCADE` in particular leaves the
  # merge worker panicking in a loop with the dictionary empty.
  #
  # There is exactly one thing to clean up, and it is not the data:
  # {.reset_dictionary_cache!}. Call it before each example that touches the
  # graph, or the second one silently reads nothing. See
  # `docs/spec-corrections.md` §11.
  #
  #     RSpec.configure do |c|
  #       c.include PgRipple::TestHelpers
  #       c.before(:each) { PgRipple::TestHelpers.reset_dictionary_cache! }
  #     end
  module TestHelpers
    # Drops the connections, and with them pg_ripple's per-backend dictionary
    # cache.
    #
    # **A rolled-back transaction poisons that cache**, which makes this the
    # one thing a transactional suite has to do and the reason the README's
    # "nothing extra to clean up" was wrong. pg_ripple 0.128.0 keeps a
    # per-backend map of term to dictionary id; a `ROLLBACK` removes the
    # dictionary rows without invalidating the map. The next transaction on
    # that connection writes triples against ids that no longer exist, and
    # every query for those terms returns **nothing** — silently, and only for
    # the terms the rolled-back example was the first to use, which is what
    # makes it look like a flaky test rather than a bug. Three rolled-back
    # rounds of insert-then-query on one connection return 1, 0, 0; with a
    # reconnect between them, 1, 1, 1. The server will also log
    # `batch_decode: dictionary entry missing for id …` once it is far enough
    # gone.
    #
    # The cache is per backend and there is no API to clear it, so the fix is
    # to drop the connection. It costs a few milliseconds and it is the
    # difference between a repeatable suite and a haunted one.
    #
    # This is deliberately not installed as a global hook by
    # `require "pg_ripple/rspec"`: disconnecting a host application's pool
    # before every example — including the ones that never touch a database —
    # is not a decision a gem gets to make silently. Add the line above.
    #
    # @return [void]
    def self.reset_dictionary_cache!
      ActiveRecord::Base.connection_pool.disconnect!
    end

    # @return [void]
    def ripple_reset_dictionary_cache!
      TestHelpers.reset_dictionary_cache!
    end

    # @param graph_name [String, RDF::URI, nil]
    # @return [PgRipple::Repository]
    def ripple_repository(graph_name: :configured)
      PgRipple.repository(graph_name: graph_name)
    end

    # Every triple in the store, or every triple about one subject.
    #
    # @param subject [PgRipple::Node, RDF::Resource, nil]
    # @return [Array<RDF::Statement>]
    def ripple_triples(subject = nil)
      return ripple_repository.statements.to_a if subject.nil?

      term = subject.respond_to?(:rdf_subject) ? subject.rdf_subject : subject

      ripple_repository.query([term, nil, nil]).to_a
    end
  end
end

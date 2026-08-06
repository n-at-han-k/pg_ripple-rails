# frozen_string_literal: true

require "active_record"
require "rdf"

require "pg_ripple"

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
  # A rolled-back transaction leaves pg_ripple's SPARQL plan cache holding
  # plans that can never match a row again ({PgRipple::PlanCache}). The gem
  # handles that for you — every rollback marks the connection and the next
  # statement resets the cache — so a transactional suite needs **no** hook of
  # its own, and the `before(:each)` line earlier versions of this README asked
  # for is no longer required.
  #
  # {.reset_plan_cache!} is here for the suites the rollback hook cannot see: a
  # suite that cleans with `TRUNCATE` or `DatabaseCleaner`, one that reaches
  # the store through SQL that never goes through this gem, or one that has
  # turned {PgRipple::Configuration#reset_plan_cache_on_rollback} off.
  #
  module TestHelpers
    # Clears pg_ripple's SPARQL plan cache on the current connection.
    #
    # Exactly {PgRipple.reset_plan_cache!} — one round trip, no reaching into
    # the host application's connection pool. It is safe to call before every
    # example and unnecessary in a suite that rolls back, because the rollback
    # already did it.
    #
    # @return [Boolean] whether the reset ran
    def self.reset_plan_cache!
      PgRipple.reset_plan_cache!
    end

    # Deprecated spelling of {.reset_plan_cache!}, kept for one release because
    # it was published in the README.
    #
    # It is not only a rename. The old implementation was
    # `ActiveRecord::Base.connection_pool.disconnect!`, and it worked by
    # accident: a new backend gets an empty plan cache. It also stated a
    # mechanism — a stale *dictionary* cache — that
    # `docs/probe-cache-invalidation.md` disproves, and it tore down a host
    # application's whole pool to clear one connection's cache.
    #
    # @deprecated Use {.reset_plan_cache!}.
    # @return [Boolean] whether the reset ran
    def self.reset_dictionary_cache!
      warn "[pg_ripple] PgRipple::TestHelpers.reset_dictionary_cache! is deprecated; " \
        "use PgRipple::TestHelpers.reset_plan_cache! (the cache is the SPARQL plan " \
        "cache, not the dictionary — see PgRipple::PlanCache)."

      reset_plan_cache!
    end

    # @return [Boolean] whether the reset ran
    def ripple_reset_plan_cache!
      TestHelpers.reset_plan_cache!
    end

    # @deprecated Use {#ripple_reset_plan_cache!}.
    # @return [Boolean] whether the reset ran
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

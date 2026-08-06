# frozen_string_literal: true

require "active_support/notifications"
require "active_triples"
require "rdf"

require "pg_ripple/persistence"
require "pg_ripple/persistence/update"

module PgRipple
  module Persistence
    # An {ActiveTriples} persistence strategy that writes only the difference.
    #
    # ActiveTriples' own {ActiveTriples::RepositoryStrategy} persists by
    # `erase_old_resource` followed by `repository << source`: every triple of
    # the subject is retracted and re-asserted on every save, whether or not it
    # moved. On pg_ripple that is not merely wasteful, and this is why the
    # README calls it an anti-pattern rather than a micro-optimisation:
    #
    # 1. **Partition churn.** A re-asserted triple lands in the delta partition
    #    and has to be merged into main again, so a save touching one property
    #    costs a merge proportional to the whole subject.
    # 2. **CDC.** pg_trickle stream tables and every subscriber downstream of
    #    them see a retraction and an assertion for facts that never changed;
    #    "the subject was rewritten" is not a change anyone can act on.
    # 3. **DRed.** Delete-and-rederive retracts everything derived from a
    #    retracted fact and then rederives it. Retracting a fact that is about
    #    to be re-asserted identically makes the reasoner do that work for
    #    nothing, and the intermediate state is briefly *visible* inside the
    #    transaction to anything reading derived facts.
    #
    # So this strategy keeps a baseline — the statements it believes the store
    # holds — and on {#persist!} emits the set difference in both directions as
    # a single `DELETE DATA … ; INSERT DATA …` request. Nothing that did not
    # move is written.
    #
    # Everything runs on the application's own connection, inside whatever
    # transaction the caller is already in. No connection is opened and no
    # transaction is started here: rows and triples commit or roll back
    # together because they are the same transaction, not because anything
    # compensates afterwards (`docs/probe-lateral-join.md` §e).
    #
    # @example
    #   alice.role = "manager"
    #   alice.save!
    #   # DELETE DATA { <…/people/1> <…/role> "engineer" } ;
    #   # INSERT DATA { <…/people/1> <…/role> "manager" }
    class DiffStrategy
      include ActiveTriples::PersistenceStrategy

      # @return [ActiveTriples::RDFSource] the resource being persisted
      attr_reader :source

      # @param source [ActiveTriples::RDFSource]
      def initialize(source)
        @source = source
        @baseline = Set.new
      end

      # The repository the difference is written to.
      #
      # @return [PgRipple::Repository]
      def repository
        @repository ||= PgRipple.repository
      end

      # @param repository [PgRipple::Repository]
      # @return [PgRipple::Repository]
      attr_writer :repository

      # Statements the store holds that the source no longer asserts.
      #
      # @return [Array<RDF::Statement>]
      def removed
        (@baseline - current).to_a
      end

      # Statements the source asserts that the store does not hold.
      #
      # @return [Array<RDF::Statement>]
      def added
        (current - @baseline).to_a
      end

      # Whether anything would be written.
      #
      # @return [Boolean]
      def changed?
        current != @baseline
      end

      # Writes the difference, and nothing else.
      #
      # @return [true]
      def persist!
        write(removed, added)
        @baseline = current
        @persisted = true
      end

      # Retracts every triple about this subject.
      #
      # @see PgRipple::Persistence.erase
      # @return [Integer] triples retracted
      def erase_old_resource
        return 0 if source.node?

        count = Persistence.erase(source.to_term, repository: repository)
        @baseline = Set.new
        count
      end

      # Retracts the source's statements, in one request.
      #
      # @see ActiveTriples::PersistenceStrategy#destroy
      def destroy
        super { source.clear }
      end

      # Reloads the subject's statements from the store and rebaselines on
      # them.
      #
      # A bounded read — one subject, whatever predicates it has — and the only
      # honest way to get a baseline. A strategy that guessed would emit a
      # `DELETE DATA` for a triple that is not there (harmless) or skip one
      # that is (data loss).
      #
      # The baseline is what the *store* returned, not the graph afterwards.
      # Those differ: `ActiveTriples::RDFSource#initialize` writes the
      # `rdf:type` statement a `configure type:` declares, so a source built
      # for a brand-new subject already asserts something the store has never
      # seen. Baselining on the merged graph would swallow exactly that triple
      # and the type would never be written — measured, not imagined.
      #
      # @return [true]
      def reload
        return true if source.node?

        loaded = Set.new

        repository.query([source.to_term, nil, nil]) do |statement|
          source << statement
          loaded << RDF::Statement.new(statement.subject, statement.predicate, statement.object)
        end

        @baseline = loaded
        @persisted = true unless loaded.empty?
        true
      end

      private

      # The source's statements as a comparable set.
      #
      # Stripped of `graph_name`: statements read back from a graph-scoped
      # repository carry it and statements built in memory do not, and a
      # baseline that compared unequal for that reason would re-assert the
      # whole subject on every save — the exact behaviour this class exists to
      # avoid.
      def current
        source.statements.map { |s| RDF::Statement.new(s.subject, s.predicate, s.object) }.to_set
      end

      # One request, both directions. `DELETE DATA … ; INSERT DATA …` is a
      # single `pg_ripple.sparql_update()` call — one round trip, and the
      # retraction and the assertion cannot end up in different transactions
      # because there is only one statement.
      def write(deleted, inserted)
        return if deleted.empty? && inserted.empty?

        update = Update.new(graph_name: repository.graph_name)
        update.delete_data(deleted)
        update.insert_data(inserted)
        repository.sparql_update(update.to_s)

        Persistence.notify(
          deleted: deleted, inserted: inserted, graph_name: repository.graph_name
        )
      end
    end
  end
end

# frozen_string_literal: true

require "active_support/notifications"
require "rdf"

require "pg_ripple/persistence/update"

module PgRipple
  # Where graph state becomes graph writes.
  module Persistence
    # The ActiveSupport::Notifications event every graph write publishes.
    #
    # Payload: `:deleted` and `:inserted`, each an array of {RDF::Statement};
    # `:deleted_count` and `:inserted_count`, which are the array sizes except
    # for a `DELETE WHERE`, whose triples the server counts but does not name;
    # and `:graph_name`.
    #
    # It exists because the *result* of a write cannot distinguish a diff from
    # a whole-object rewrite — both leave the store in the same state, so no
    # before/after comparison can tell them apart. `change_triples` therefore
    # watches the write itself. It is also the seam a host application's audit
    # or cache-expiry code can hang off without patching this gem.
    WRITE = "write.pg_ripple"

    module_function

    # @param deleted [Array<RDF::Statement>] the retracted statements, when
    #   they are known
    # @param inserted [Array<RDF::Statement>]
    # @param deleted_count [Integer] retracted triples, including those a
    #   `DELETE WHERE` removed without naming
    # @param inserted_count [Integer]
    # @param graph_name [RDF::URI, nil]
    # @return [void]
    # @api private
    def notify(deleted: [], inserted: [], deleted_count: deleted.size,
      inserted_count: inserted.size, graph_name: nil)
      return if deleted_count.zero? && inserted_count.zero?

      ActiveSupport::Notifications.instrument(
        WRITE,
        deleted: deleted, inserted: inserted,
        deleted_count: deleted_count, inserted_count: inserted_count,
        graph_name: graph_name
      ) { nil }
    end

    # Asserts exactly these statements, as one `INSERT DATA`.
    #
    # What `alice.friends << bob` emits. One request rather than a
    # `pg_ripple.insert_triple()` per statement, so a `<<` of several records is
    # one round trip and the whole thing is one entry in the {WRITE} stream.
    #
    # @param statements [Enumerable<RDF::Statement>]
    # @param repository [PgRipple::Repository]
    # @return [Integer] triples asserted
    def assert(statements, repository: PgRipple.repository)
      statements = Array(statements)
      return 0 if statements.empty?

      update = Update.new(graph_name: repository.graph_name)
      update.insert_data(statements)
      count = repository.sparql_update(update.to_s)
      notify(inserted: statements, inserted_count: count, graph_name: repository.graph_name)
      count
    end

    # Retracts exactly these statements, as one `DELETE DATA`.
    #
    # What `alice.friends.delete(bob)` emits.
    #
    # @param statements [Enumerable<RDF::Statement>]
    # @param repository [PgRipple::Repository]
    # @return [Integer] triples retracted
    def retract(statements, repository: PgRipple.repository)
      statements = Array(statements)
      return 0 if statements.empty?

      update = Update.new(graph_name: repository.graph_name)
      update.delete_data(statements)
      count = repository.sparql_update(update.to_s)
      notify(deleted: statements, deleted_count: count, graph_name: repository.graph_name)
      count
    end

    # Retracts every triple whose subject is `subject`.
    #
    # The whole-subject `DELETE WHERE` the README names as the anti-pattern,
    # used in the one place it is not one: the subject is going away, so there
    # is nothing to preserve and no diff worth computing. Authoritative even
    # when this process never loaded the subject's graph, which a diff would
    # not be.
    #
    # @param subject [RDF::URI]
    # @param repository [PgRipple::Repository]
    # @return [Integer] triples retracted
    def erase(subject, repository: PgRipple.repository)
      run(repository) { |update| update.delete_where(subject: subject) }
    end

    # Retracts every triple whose object is `subject`.
    #
    # `graph dependent: :nullify_references`. Not the default: an inbound
    # sweep is a scan the store cannot answer from the subject's own index, and
    # "drop the row, keep the dangling edge" is a defensible choice —
    # `graph_has_many` has no foreign key either.
    #
    # @param subject [RDF::URI]
    # @param repository [PgRipple::Repository]
    # @return [Integer] triples retracted
    def nullify_references(subject, repository: PgRipple.repository)
      run(repository) { |update| update.delete_where(object: subject) }
    end

    # @api private
    def run(repository)
      update = Update.new(graph_name: repository.graph_name)
      yield update
      return 0 if update.empty?

      count = repository.sparql_update(update.to_s)
      notify(deleted_count: count, graph_name: repository.graph_name)
      count
    end
  end
end

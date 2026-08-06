# frozen_string_literal: true

module PgRipple
  # pg_ripple's configuration object.
  #
  # Two halves, and they are set in the same block because a host application
  # thinks of them as one setting list. The schema half ({#adapter},
  # {#dump_ripple_objects_at_beginning_of_schema}) belongs to migrations and
  # `db:schema:dump`; the graph half ({#base_uri}, {#default_graph},
  # {#validate}, {#strict_loading}) belongs to models and the repository.
  #
  # @example config/initializers/pg_ripple.rb
  #   PgRipple.configure do |c|
  #     c.base_uri      = "https://app.example.com/"
  #     c.default_graph = nil            # nil = default graph
  #     c.validate      = :sync          # :sync | :async | :off
  #     c.strict_loading = Rails.env.local?
  #   end
  class Configuration
    # The validation modes {#validate} accepts, which are pg_ripple's own
    # `pg_ripple.shacl_mode` settings and not a Rails-side invention.
    VALIDATION_MODES = %i[sync async off].freeze

    # The adapter every pg_ripple statement and catalog read runs through.
    #
    # Defaults to an instance of {PgRipple::Adapters::Postgres}, which uses the
    # application's own ActiveRecord connection. It is swappable so a test can
    # substitute a double, and so a host app can subclass the adapter to change
    # dump ordering without reopening this gem.
    #
    # @return [PgRipple::Adapters::Postgres]
    attr_accessor :adapter

    # Dump pg_ripple objects before the tables rather than after.
    #
    # Off by default: a SPARQL view generally reads prefixes and triples that
    # the tables above it populate, so after-`super` is the safe order. Turn it
    # on for F(x)'s reason — a column default that calls into the store needs
    # the store's objects to already exist when `db:schema:load` reaches it.
    #
    # @return [Boolean]
    attr_accessor :dump_ripple_objects_at_beginning_of_schema

    # Whether an association traversal may fire a query lazily.
    #
    # Rails' own flag, applied to the graph: with it on, reading an unloaded
    # graph association raises instead of walking the store. It is worth more
    # here than it is on a `has_many`, because the query behind a property path
    # is a whole SPARQL evaluation and `+`/`*` paths are unbounded — see
    # "Where the abstraction leaks" in the README.
    #
    # @return [Boolean]
    attr_accessor :strict_loading

    # The IRI every minted subject hangs off, e.g. "https://app.example.com/".
    #
    # A model's `iri:` lambda returns a relative path ("people/1") and this is
    # what it is resolved against, so the same row is the same subject in every
    # environment only if every environment agrees on this value.
    #
    # Kept as the string it was given rather than coerced to an {RDF::URI}: the
    # coercion belongs at the join, where `RDF::URI.new(base_uri).join(path)`
    # is the operation that has the trailing-slash rule in it.
    #
    # @return [String, nil]
    attr_accessor :base_uri

    # The named graph reads and writes are scoped to. `nil` = the default graph.
    #
    # A graph is not a schema object — pg_ripple has no catalog of empty graphs
    # (`probe-results.md` §3), a graph exists exactly as long as a triple names
    # it — so this is configuration and never a migration.
    #
    # @return [String, RDF::URI, nil]
    attr_accessor :default_graph

    # Reset pg_ripple's SPARQL plan cache on the connection after a rollback.
    #
    # On by default, and it should stay on: with it off, an aborted
    # transaction leaves the connection it ran on answering some queries with
    # zero rows for the rest of its life. See {PgRipple::PlanCache} for the
    # mechanism and `docs/probe-cache-invalidation.md` for the measurements.
    #
    # It costs one `SELECT pg_ripple.plan_cache_reset()` after a rollback, on a
    # connection that has actually run a pg_ripple statement, and nothing at
    # all on one that has not. Turn it off only if you are resetting the cache
    # yourself, and know that `PgRipple.reset_plan_cache!` is then your job.
    #
    # @return [Boolean]
    attr_accessor :reset_plan_cache_on_rollback

    # When SHACL validation runs relative to the write that triggers it.
    #
    # One of `:sync`, `:async`, `:off`. `:sync` maps to pg_ripple's own
    # `pg_ripple.shacl_mode`, which `insert_triple` reads to reject an invalid
    # triple in the writing transaction.
    #
    # @return [Symbol]
    attr_reader :validate

    # @param mode [Symbol, String] one of {VALIDATION_MODES}
    # @raise [ArgumentError] on anything else — a typo here silently disables
    #   validation, which is the one misconfiguration that fails open.
    def validate=(mode)
      mode = mode.to_sym

      unless VALIDATION_MODES.include?(mode)
        raise ArgumentError,
          "PgRipple validate must be one of #{VALIDATION_MODES.map(&:inspect).join(", ")}, got #{mode.inspect}"
      end

      @validate = mode
    end

    def initialize
      @adapter = PgRipple::Adapters::Postgres.new
      @dump_ripple_objects_at_beginning_of_schema = false
      @base_uri = nil
      @default_graph = nil
      @validate = :sync
      @strict_loading = false
      @reset_plan_cache_on_rollback = true
    end
  end
end

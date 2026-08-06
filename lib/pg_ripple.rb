# frozen_string_literal: true

require "active_record"

require "pg_ripple/version"

# Definition first: it owns the `db/ripple` directory constant that the value
# objects and Configuration read, and requiring it later raises NameError at
# boot. Adapter before Configuration for the same reason — Configuration
# instantiates PgRipple::Adapters::Postgres.
require "pg_ripple/definition"
require "pg_ripple/plan_cache"
require "pg_ripple/adapters/postgres"
require "pg_ripple/configuration"

require "pg_ripple/prefix"
require "pg_ripple/shape"
require "pg_ripple/rule_set"
require "pg_ripple/sparql_view"
require "pg_ripple/endpoint"

require "pg_ripple/term"
require "pg_ripple/prefixes"
require "pg_ripple/handlers/sparql_path"
require "pg_ripple/path"
require "pg_ripple/persistence"
require "pg_ripple/persistence/update"
require "pg_ripple/repository"
require "pg_ripple/persistence/diff_strategy"
require "pg_ripple/query"
require "pg_ripple/relation"
require "pg_ripple/preloader"
require "pg_ripple/preloading"
require "pg_ripple/associations"
require "pg_ripple/node"

require "pg_ripple/statements"
require "pg_ripple/command_recorder"
require "pg_ripple/migration_dsl"
require "pg_ripple/schema_dumper"

require "pg_ripple/railtie" if defined?(::Rails::Railtie)

# pg_ripple puts an RDF knowledge graph behind ActiveRecord.
#
# Two halves, sharing one connection. The schema half teaches ActiveRecord's
# migration DSL, its rollback machinery and its schema dumper about the
# pg_ripple objects that are schema rather than data: prefixes, SHACL shape
# sets, Datalog rule sets, SPARQL views and federation endpoints. The data half
# is {PgRipple::Repository}, an {RDF::Repository} over the application's own
# connection, and {.select} on top of it.
module PgRipple
  # The name {PgRipple::Repository} is registered under in ActiveTriples'
  # global repository registry.
  #
  # Only `ActiveTriples::RepositoryStrategy` — the opt-back-in the README's
  # "How writes work" documents — looks it up. The default
  # {PgRipple::Persistence::DiffStrategy} is handed a repository directly.
  REPOSITORY_NAME = :pg_ripple

  # Hooks pg_ripple into Rails.
  #
  # Enables the `*_ripple_*` migration methods, the `ripple do … end` block
  # that gives them their short names, migration reversibility, and `schema.rb`
  # dumping. F(x)'s three mix-ins, plus ours.
  #
  # {PgRipple::MigrationDsl} goes onto `ActiveRecord::Migration` and adds
  # exactly one name, `ripple`. The short names it exposes are defined on a
  # receiver of our own and are deliberately NOT on the adapter, where they
  # would shadow another gem's — see {PgRipple::MigrationDsl}.
  def self.load
    ActiveRecord::Migration::CommandRecorder.include(PgRipple::CommandRecorder)
    ActiveRecord::ConnectionAdapters::AbstractAdapter.include(PgRipple::Statements)
    ActiveRecord::Migration.include(PgRipple::MigrationDsl)
    ActiveRecord::SchemaDumper.prepend(PgRipple::SchemaDumper)

    install_plan_cache_invalidation

    true
  end

  # Marks a connection whose transaction rolled back, so the next pg_ripple
  # statement on it resets the stale SPARQL plan cache first.
  #
  # Prepended onto `PostgreSQLAdapter` and not onto `AbstractAdapter`, where
  # the other mix-ins go: `PostgreSQL::DatabaseStatements` defines
  # `#exec_rollback_db_transaction` itself, so a module prepended to the
  # abstract class sits below it in the ancestors and is never reached. The
  # load hook fires immediately if the adapter is already loaded.
  #
  # @see PgRipple::PlanCache
  def self.install_plan_cache_invalidation
    ActiveSupport.on_load(:active_record_postgresqladapter) do
      prepend PgRipple::PlanCache::Invalidation
    end
  end

  # @return [PgRipple::Configuration] pg_ripple's current configuration
  def self.configuration
    @_configuration ||= PgRipple::Configuration.new
  end

  # Set pg_ripple's configuration.
  #
  # @param config [PgRipple::Configuration]
  def self.configuration=(config)
    @_configuration = config
    @_repositories = nil
  end

  # Modify pg_ripple's current configuration.
  #
  # @yieldparam [PgRipple::Configuration] config current pg_ripple config
  # ```
  # PgRipple.configure do |config|
  #   config.base_uri = "https://app.example.com/"
  #   config.default_graph = nil
  #   config.validate = :sync
  #   config.strict_loading = Rails.env.local?
  # end
  # ```
  #
  # The memoised repositories are discarded, because {Configuration#default_graph}
  # is what the default one is scoped to and a repository built before the
  # initializer ran would be pointed at the wrong graph for the rest of the
  # process.
  def self.configure
    yield configuration
    @_repositories = nil
  end

  # The repository, over the application's own ActiveRecord connection.
  #
  # Memoised per graph. The instance holds no connection of its own — it asks
  # `ActiveRecord::Base` for one on every statement — so memoising it survives
  # a fork, a reconnect and a `clear_active_connections!`.
  #
  # @param graph_name [String, RDF::URI, nil] a named graph. Omitted, the
  #   repository is scoped to {Configuration#default_graph}.
  # @return [PgRipple::Repository]
  def self.repository(graph_name: :configured)
    # Normalised before it is used as a memo key: `:configured` and the graph
    # it resolves to are the same repository, and two instances for one graph
    # means a caller can stub one and be handed the other.
    graph_name = configuration.default_graph if graph_name == :configured

    @_repositories ||= {}
    @_repositories[graph_name] ||= PgRipple::Repository.new(graph_name: graph_name)
  end

  # Runs a SPARQL SELECT against the configured graph.
  #
  # ```ruby
  # PgRipple.select(<<~SPARQL)
  #   SELECT ?s ?name WHERE { ?s foaf:knows+ ?friend ; foaf:name ?name }
  # SPARQL
  # # => [#<RDF::Query::Solution s=... name=...>, ...]
  # ```
  #
  # @param query [String] a SPARQL SELECT query
  # @return [RDF::Query::Solutions]
  def self.select(query, &block)
    repository.sparql(query, &block)
  end

  # Runs a SPARQL ASK against the configured graph.
  #
  # @param query [String] a SPARQL ASK query
  # @return [Boolean]
  def self.ask(query)
    repository.ask(query)
  end

  # The database adapter pg_ripple statements and catalog reads run through.
  #
  # Defaults to {PgRipple::Adapters::Postgres} and is overridable via
  # {Configuration}.
  def self.database
    configuration.adapter
  end

  # Alias of {.database}, for callers that think of it as a connection.
  def self.connection
    configuration.adapter
  end

  # Clears pg_ripple's SPARQL plan cache on the current connection.
  #
  # The gem does this for you after a rollback — see {PgRipple::PlanCache} —
  # so this is the escape hatch for the cases it cannot see: a suite that
  # cleans with `TRUNCATE` rather than a transaction, a connection poisoned by
  # SQL that did not go through this gem, or
  # {PgRipple::Configuration#reset_plan_cache_on_rollback} turned off.
  #
  # Warns once and returns false if the reset fails — which on a database
  # without the extension it will, because there is then no
  # `pg_ripple.plan_cache_reset()` to call.
  #
  # @return [Boolean] whether the reset ran
  def self.reset_plan_cache!
    if ActiveRecord::Base.respond_to?(:with_connection)
      ActiveRecord::Base.with_connection { |conn| PgRipple::PlanCache.reset!(conn) }
    else
      PgRipple::PlanCache.reset!(ActiveRecord::Base.connection)
    end
  end
end

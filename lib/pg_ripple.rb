# frozen_string_literal: true

require "active_record"

require "pg_ripple/version"

# Definition first: it owns the `db/ripple` directory constant that the value
# objects and Configuration read, and requiring it later raises NameError at
# boot. Adapter before Configuration for the same reason — Configuration
# instantiates PgRipple::Adapters::Postgres.
require "pg_ripple/definition"
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
require "pg_ripple/associations"
require "pg_ripple/node"

require "pg_ripple/statements"
require "pg_ripple/command_recorder"
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
  # Enables the `*_ripple_*` migration methods, migration reversibility, and
  # `schema.rb` dumping. Three mix-ins, in F(x)'s order.
  def self.load
    ActiveRecord::Migration::CommandRecorder.include(PgRipple::CommandRecorder)
    ActiveRecord::ConnectionAdapters::AbstractAdapter.include(PgRipple::Statements)
    ActiveRecord::SchemaDumper.prepend(PgRipple::SchemaDumper)

    true
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
end

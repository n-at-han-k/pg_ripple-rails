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

require "pg_ripple/statements"
require "pg_ripple/command_recorder"
require "pg_ripple/schema_dumper"

require "pg_ripple/railtie" if defined?(::Rails::Railtie)

# pg_ripple teaches ActiveRecord's migration DSL, its rollback machinery and its
# schema dumper about the pg_ripple objects that are schema rather than data:
# prefixes, SHACL shape sets, Datalog rule sets, SPARQL views and federation
# endpoints.
#
# Queries — `sparql()`, `validate()`, `infer()` — are not wrapped; call them on
# `ActiveRecord::Base.connection` directly.
module PgRipple
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
  end

  # Modify pg_ripple's current configuration.
  #
  # @yieldparam [PgRipple::Configuration] config current pg_ripple config
  # ```
  # PgRipple.configure do |config|
  #   config.adapter = PgRipple::Adapters::Postgres.new
  #   config.dump_ripple_objects_at_beginning_of_schema = true
  # end
  # ```
  def self.configure
    yield configuration
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

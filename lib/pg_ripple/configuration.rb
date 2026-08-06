# frozen_string_literal: true

module PgRipple
  # pg_ripple's configuration object.
  class Configuration
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

    def initialize
      @adapter = PgRipple::Adapters::Postgres.new
      @dump_ripple_objects_at_beginning_of_schema = false
    end
  end
end

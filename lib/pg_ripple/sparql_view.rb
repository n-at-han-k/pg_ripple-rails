# frozen_string_literal: true

# `String#indent`, for laying the query out under its heredoc — see the note in
# rule_set.rb.
require "active_support/core_ext/string/indent"

module PgRipple
  # A SPARQL view as it exists in `_pg_ripple.sparql_views`, and how it is
  # written back into `db/schema.rb`.
  #
  # `schedule` and `decode` are carried because a SPARQL view is a scheduled
  # pg_trickle stream table and both are part of its definition; `immediate` is
  # not, because it is an action taken at creation time and the catalog keeps
  # no record of it.
  #
  # @api private
  class SparqlView
    include Comparable

    attr_reader :name, :sparql, :schedule, :decode

    def initialize(row)
      @name = row.fetch("name")
      @sparql = row.fetch("sparql")
      @schedule = row.fetch("schedule", nil)
      @decode = row.fetch("decode", nil)
    end

    def <=>(other)
      name <=> other.name
    end

    def ==(other)
      name == other.name &&
        sparql == other.sparql &&
        schedule == other.schedule &&
        decode == other.decode
    end

    # `_pg_ripple.sparql_views.sparql` is the query text exactly as passed to
    # `create_sparql_view`, so this is a verbatim dump rather than a
    # reconstruction — the same position F(x) is in with `pg_get_functiondef`,
    # and the opposite of pg_cron's.
    #
    # The heredoc is single-quoted (`<<-'SPARQL'`) and this one has teeth: a
    # SPARQL query is full of `?vars`, `#` comments and `$` — Ruby would read
    # `#{...}` in a query as interpolation and a double-quoted heredoc would
    # mangle it.
    #
    # `schedule` and `decode` are always written, never left to the server's
    # defaults, so the dumped value and the created value cannot drift apart.
    # `immediate` is not written at all: it has no column, it says whether to
    # populate the stream table on creation rather than anything about the
    # view, and emitting a guess would be a fabrication. A schema-loaded view
    # populates on its first scheduled refresh instead.
    #
    # @return [String] a `create_ripple_sparql_view` call, indented for
    #   `schema.rb`
    def to_schema
      <<~SCHEMA.indent(2).rstrip
        create_ripple_sparql_view #{name.inspect}, schedule: #{dumped_schedule.inspect}, decode: #{decode == true}, definition: <<-'SPARQL'
        #{sparql.indent(4).rstrip}
        SPARQL
      SCHEMA
    end

    private

    # A view predating a column default, or read through an adapter double,
    # can arrive with no schedule; the create would apply this value anyway.
    def dumped_schedule
      schedule || PgRipple::Adapters::Postgres::DEFAULT_VIEW_SCHEDULE
    end
  end
end

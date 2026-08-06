# frozen_string_literal: true

require "active_record"
require "pg_ripple"
require "pg_ripple/test_helpers"

# Connects the suite to a pg_ripple database, when one is offered.
#
# Specs tagged `:database` need a real PostgreSQL with the extension loaded —
# an ActiveRecord model cannot even be defined without a table to reflect on.
# Set PG_RIPPLE_TEST_URL to run them; without it they are skipped rather than
# failed, because a unit run must not depend on a container.
module DatabaseHelper
  URL = ENV["PG_RIPPLE_TEST_URL"]

  module_function

  def available?
    !URL.nil? && !URL.empty?
  end

  def connect!
    return @connected if defined?(@connected)

    ActiveRecord::Base.establish_connection(URL)
    ActiveRecord::Base.lease_connection.execute("CREATE EXTENSION IF NOT EXISTS pg_ripple")
    @connected = true
  end

  # @param sql [String]
  def execute(sql)
    ActiveRecord::Base.lease_connection.execute(sql)
  end
end

RSpec.configure do |config|
  config.before(:suite) do
    DatabaseHelper.connect! if DatabaseHelper.available?
  end

  config.before(:each, :database) do
    skip "set PG_RIPPLE_TEST_URL to run database specs" unless DatabaseHelper.available?
  end

  config.around(:each, :database) do |example|
    next example.run unless DatabaseHelper.available?

    # A rolled-back transaction takes the triples with it, but *not* the
    # dictionary ids it minted: pg_ripple 0.128.0 keeps a per-backend cache of
    # term-to-id, and after a `ROLLBACK` that cache still holds ids whose rows
    # are gone. The next transaction on that connection then writes triples
    # against stale ids and every query for those terms returns nothing —
    # silently, and only for terms the rolled-back example was the first to
    # use. Measured: three rounds of insert-then-query in three rolled-back
    # transactions on one connection return 1, 0, 0; the same three with a
    # reconnect in between return 1, 1, 1; and three rounds using a *fresh*
    # term each time return 1, 1, 1 with no reconnect. Dropping the connection
    # drops the cache, which is why this is here and not in the example.
    #
    # `PgRipple::TestHelpers.reset_dictionary_cache!` is the shipped spelling —
    # the same line a host application's suite needs, so this suite runs the
    # thing the README tells other people to run.
    PgRipple::TestHelpers.reset_dictionary_cache!

    ActiveRecord::Base.transaction do
      example.run
      raise ActiveRecord::Rollback
    end
  end
end

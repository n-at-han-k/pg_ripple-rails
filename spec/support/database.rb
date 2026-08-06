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

    # What `PgRipple::Railtie` does in an application, done by hand because
    # this suite has no application. Among other things it installs the
    # rollback hook that resets the SPARQL plan cache
    # ({PgRipple::PlanCache}), which the suite depends on for exactly the
    # reason a host app does.
    PgRipple.load
    ActiveRecord::Base.with_connection { |c| c.execute("CREATE EXTENSION IF NOT EXISTS pg_ripple") }
    @connected = true
  end

  # @param sql [String]
  def execute(sql)
    ActiveRecord::Base.with_connection { |c| c.execute(sql) }
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

    # `:no_transaction` opts out of the wrapper, for the one thing it cannot
    # host: an example about what a *top-level* rollback does. Nested in this
    # transaction, `raise ActiveRecord::Rollback` is a savepoint rollback, and
    # a savepoint rollback has a second pg_ripple defect on it
    # (`docs/probe-cache-invalidation.md`, defect B) that would mask the one
    # under test. Such an example is responsible for its own cleanup — the ones
    # here roll every round back themselves and commit nothing.
    next example.run if example.metadata[:no_transaction]

    # No cache reset here, deliberately. A rolled-back transaction poisons
    # pg_ripple's per-backend SPARQL plan cache and the next example on that
    # connection reads nothing (`docs/probe-cache-invalidation.md`) — but the
    # gem now marks the connection on rollback and resets the cache before its
    # next statement, so the suite runs the same code path a host application
    # runs and would go red if that path broke. `PgRipple::TestHelpers` still
    # ships `reset_plan_cache!` for the suites the hook cannot see; it has its
    # own spec.
    ActiveRecord::Base.transaction do
      example.run
      raise ActiveRecord::Rollback
    end
  end
end

# frozen_string_literal: true

require "spec_helper"

# `ActiveRecord::Base.connection` is the deprecated permanent-checkout API.
# Rails is moving towards `permanent_connection_checkout = :disallowed`, and
# under it the *whole gem* raised — reads, writes and migrations alike, and
# from inside an application's own `with_connection` block too, so there was no
# way to scope around it. `#lease_connection` is the same lease without the
# deprecation.
RSpec.describe "the connection this gem leases", :database do
  around do |example|
    previous = ActiveRecord.permanent_connection_checkout
    ActiveRecord.permanent_connection_checkout = :disallowed
    example.run
  ensure
    ActiveRecord.permanent_connection_checkout = previous
  end

  before do
    skip "this Rails does not have permanent_connection_checkout" unless
      ActiveRecord.respond_to?(:permanent_connection_checkout=)
  end

  it "reads the graph with permanent checkout disallowed" do
    expect { PgRipple.repository.count }.not_to raise_error
  end

  it "runs a migration statement with permanent checkout disallowed" do
    expect { PgRipple.configuration.adapter.prefixes }.not_to raise_error
  end
end

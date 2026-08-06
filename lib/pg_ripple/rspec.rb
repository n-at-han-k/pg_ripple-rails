# frozen_string_literal: true

require "rspec/core"

require "pg_ripple"
require "pg_ripple/test_helpers"
require "pg_ripple/rspec/matchers/change_triples"
require "pg_ripple/rspec/matchers/have_triple"

module PgRipple
  # The RSpec integration, loaded by `require "pg_ripple/rspec"`.
  #
  # Only the matchers are included automatically — a matcher is a name in the
  # example group and nothing else, so it costs a host suite nothing.
  # {PgRipple::TestHelpers} is opt-in, as the README shows, because it defines
  # instance methods and a suite is entitled to decide where those land.
  module RSpec
    # `have_triple`, `change_triples`.
    #
    # The other three names the README lists — `be_derived`, `violate_shape`,
    # `entail` — belong to inference and SHACL validation, which this gem does
    # not implement yet. They are absent rather than stubbed: a matcher that
    # always passed would be worse than a `NoMethodError`.
    module Matchers
    end
  end
end

RSpec.configure do |config|
  config.include PgRipple::RSpec::Matchers
end

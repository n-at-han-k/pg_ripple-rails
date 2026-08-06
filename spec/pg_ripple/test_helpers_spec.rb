# frozen_string_literal: true

require "spec_helper"
require "pg_ripple/test_helpers"

RSpec.describe PgRipple::TestHelpers do
  describe ".reset_plan_cache!" do
    it "clears the plan cache on the current connection", :database do
      expect(described_class.reset_plan_cache!).to be(true)
    end

    it "is the same thing PgRipple.reset_plan_cache! is" do
      allow(PgRipple).to receive(:reset_plan_cache!).and_return(true)

      described_class.reset_plan_cache!

      expect(PgRipple).to have_received(:reset_plan_cache!)
    end
  end

  # The published name, and it named the wrong cache: the hazard is the SPARQL
  # plan cache, not the dictionary (`docs/probe-cache-invalidation.md`). It
  # also used to be `connection_pool.disconnect!`, which cleared the cache only
  # as a side effect of throwing away a host application's whole pool.
  describe ".reset_dictionary_cache!" do
    it "warns and delegates to .reset_plan_cache!" do
      allow(described_class).to receive(:reset_plan_cache!).and_return(true)
      allow(described_class).to receive(:warn)

      described_class.reset_dictionary_cache!

      expect(described_class).to have_received(:warn).with(/deprecated/)
      expect(described_class).to have_received(:reset_plan_cache!)
    end
  end

  describe "#ripple_reset_plan_cache!" do
    it "is the instance-method spelling, for a suite that includes the module" do
      includer = Class.new { include PgRipple::TestHelpers }.new
      allow(described_class).to receive(:reset_plan_cache!).and_return(true)

      expect(includer.ripple_reset_plan_cache!).to be(true)
    end
  end
end

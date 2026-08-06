# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# The CI matrix pins a Rails version here rather than in the gemspec, which
# keeps its floor at 7.0 for host apps.
rails_version = ENV.fetch("RAILS_VERSION", "8.0")

if rails_version == "main"
  gem "activerecord", github: "rails/rails", branch: "main"
  gem "activesupport", github: "rails/rails", branch: "main"
  gem "railties", github: "rails/rails", branch: "main"
else
  gem "activerecord", "~> #{rails_version}.0"
  gem "activesupport", "~> #{rails_version}.0"
  gem "railties", "~> #{rails_version}.0"
end

gem "pry"
gem "redcarpet"

# Not a dependency of the gem, and deliberately so: it is here because the
# README's central claim is that `alice.network.where(active: true)
# .includes(:account).page(2)` works, and `.page` is Kaminari's. A claim about
# a third-party gem is worth exactly as much as the test that runs it.
gem "kaminari-activerecord"

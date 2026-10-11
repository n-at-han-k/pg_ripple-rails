# frozen_string_literal: true

# kettle-jem:freeze
# To retain chunks of comments & code during kettle-jem templating:
# Wrap custom sections with freeze markers (e.g., as above and below this comment chunk).
# kettle-jem will then preserve content between those markers across template runs.
# kettle-jem:unfreeze

source "https://rubygems.org"

git_source(:github) { |repo_name| "git@github.com:#{repo_name}.git" }
git_source(:codeberg) { |repo_name| "https://codeberg.org/#{repo_name}" }
git_source(:gitlab) { |repo_name| "https://gitlab.com/#{repo_name}" }

#### IMPORTANT #######################################################
# Gemfile is for local development ONLY; Gemfile is NOT loaded in CI #
####################################################### IMPORTANT ####

# Include dependencies from pg_ripple-rails.gemspec
gemspec

gem "kettle-family", "~> 1.3", ">= 1.3.1"

# Local workspace dependency wiring for *_local.gemfile overrides
gem "nomono", "~> 1.1", ">= 1.1.5", require: false # ruby >= 3.2.0

# Templating (env-switched: STRUCTUREDMERGE_DEV=/path/to/structuredmerge/ruby/gems for local paths)
eval_gemfile "gemfiles/modular/templating.gemfile" if ENV.fetch("K_JEM_TEMPLATING", "false").casecmp("true").zero?

# Debugging
eval_gemfile "gemfiles/modular/debug.gemfile"

# Code Coverage (env-switched: KETTLE_DEV_DEV=true for local paths)
eval_gemfile "gemfiles/modular/coverage.gemfile"

# Linting
eval_gemfile "gemfiles/modular/style.gemfile"

# Documentation
eval_gemfile "gemfiles/modular/documentation.gemfile"

# Changelog release tooling (available on Ruby versions supported by kettle-changelog)
eval_gemfile "gemfiles/modular/changelog.gemfile"

# Optional
eval_gemfile "gemfiles/modular/optional.gemfile"

### Std Lib Extracted Gems
eval_gemfile "gemfiles/modular/x_std_libs.gemfile"

# See unlocked_deps appraisal for more details on irb inclusion
gem "irb", "~> 1.17" # ruby >= 2.7
# The CI matrix pins a Rails version here rather than in the gemspec, which
# keeps its floor at 7.0 for host apps.
rails_version = ENV.fetch("RAILS_VERSION", "8.0")

if rails_version == "main"
else
end

gem "pry"
gem "redcarpet"

# Not a dependency of the gem, and deliberately so: it is here because the
# README's central claim is that `alice.network.where(active: true)
# .includes(:account).page(2)` works, and `.page` is Kaminari's. A claim about
# a third-party gem is worth exactly as much as the test that runs it.
gem "kaminari-activerecord"

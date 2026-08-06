# frozen_string_literal: true

require "rails"
require "active_record/railtie"

require "pg_ripple"

# In a host application `pg_ripple` is required from the Gemfile, which Bundler
# loads *after* `rails`, so the conditional `require "pg_ripple/railtie"` at the
# bottom of `lib/pg_ripple.rb` fires on its own. Here the suite has already
# required the gem from `spec/spec_helper.rb` — before any of Rails exists — so
# the conditional saw no `Rails::Railtie` and skipped. Requiring it explicitly
# is what makes this dummy behave like a real host app rather than like the
# unit suite that loaded it.
require "pg_ripple/railtie"

module Dummy
  # The smallest Rails application that can hold an ActiveRecord model with an
  # `iri` column. No Action Pack, no Action View, no assets — nothing in the
  # slice under test involves a request.
  class Application < Rails::Application
    config.root = File.expand_path("..", __dir__)
    config.load_defaults 8.0

    config.eager_load = false
    config.logger = ActiveSupport::Logger.new(IO::NULL)
    config.active_support.deprecation = :stderr
    config.secret_key_base = "pg_ripple_rails_dummy_secret_key_base"

    # The suite loads `db/schema.rb` itself, once, outside the transactional
    # fixture. Rails' own check would want a `db/migrate` and an
    # `ar_internal_metadata` handshake this app has no use for.
    config.active_record.maintain_test_schema = false
  end
end

# frozen_string_literal: true

require "rails/railtie"

module PgRipple
  # Initializes pg_ripple in the context of a Rails application once
  # ActiveRecord is loaded.
  #
  # @see PgRipple.load
  class Railtie < ::Rails::Railtie
    railtie_name :pg_ripple

    initializer "pg_ripple.load" do
      ActiveSupport.on_load :active_record do
        PgRipple.load
      end
    end

    rake_tasks do
      path = File.expand_path("..", __dir__)
      Dir.glob("#{path}/tasks/**/*.rake").each { |task| load task }
    end
  end
end

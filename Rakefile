# frozen_string_literal: true

require "standard/rake"

# The dummy app's own tasks, re-exposed as `rake dummy:db:create` and friends,
# which bin/setup uses. Guarded because the dummy app arrives with the specs.
if File.exist?(File.expand_path("spec/dummy/config/application.rb", __dir__))
  namespace :dummy do
    require_relative "spec/dummy/config/application"
    Dummy::Application.load_tasks
  end
end

task(:spec).clear
desc "Run specs other than spec/acceptance"

desc "Run acceptance specs in spec/acceptance"

desc "Run the specs, the acceptance tests and standardrb"

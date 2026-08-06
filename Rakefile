# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
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
RSpec::Core::RakeTask.new("spec") do |task|
  task.exclude_pattern = "spec/acceptance/**/*_spec.rb"
  task.verbose = false
end

desc "Run acceptance specs in spec/acceptance"
RSpec::Core::RakeTask.new("spec:acceptance") do |task|
  task.pattern = "spec/acceptance/**/*_spec.rb"
  task.verbose = false
end

desc "Run the specs, the acceptance tests and standardrb"
task default: %w[spec spec:acceptance standard]

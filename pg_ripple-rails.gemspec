# frozen_string_literal: true

lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "pg_ripple/version"

Gem::Specification.new do |spec|
  spec.name = "pg_ripple-rails"
  spec.version = PgRipple::VERSION
  spec.authors = ["Nathan Kidd"]
  spec.email = ["nathankidd@hey.com"]
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.summary = "pg_ripple knowledge graphs for Rails: models, migrations and SPARQL"
  spec.description = <<~DESCRIPTION
    Puts an RDF knowledge graph behind ActiveRecord. Mirrors columns into
    triples, traverses property paths as associations, and teaches the Rails
    migration DSL, db:rollback and db/schema.rb about the pg_ripple objects
    that are schema rather than data: prefixes, SHACL shape sets, Datalog rule
    sets, SPARQL views and federation endpoints.
  DESCRIPTION
  spec.homepage = "https://github.com/n-at-han-k/pg_ripple-rails"
  spec.metadata = {
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "changelog_uri" => "#{spec.homepage}/blob/v#{spec.version}/CHANGELOG.md",
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage
  }

  spec.files = `git ls-files -z`.split("\x0").reject do |f|
    f == File.basename(__FILE__) || f.start_with?("spec/", "references/", ".github/")
  end
  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", ">= 7.1"
  spec.add_dependency "activesupport", ">= 7.1"
  spec.add_dependency "railties", ">= 7.1"

  # The graph half of the gem. Each is pinned to the exact version the design
  # was verified against and left open to the rest of its compatible series:
  # `~>` alone would allow an older patch than the one the behaviour was read
  # from, and an `=` pin would fight every host application's lockfile.
  #
  # rdf            terms, Repository, the N-Triples reader/writer that decodes
  #                every binding pg_ripple.sparql() hands back.
  # active-triples RDFSource and the `property` DSL behind PgRipple::Node.
  #                Its own floors are permissive — activemodel >= 3.0.0,
  #                ruby >= 2.1 — so it does not hold Rails back
  #                (docs/spec-corrections.md §6).
  # sparql         the READ side: parse, #variables, Operator#rewrite. Not
  #                sparql-client, whose Queryable mode evaluates the algebra in
  #                Ruby one pattern at a time and bypasses the extension.
  # string_builder the WRITE side: property paths, Datalog, Turtle.
  spec.add_dependency "rdf", "~> 3.3", ">= 3.3.4"
  spec.add_dependency "active-triples", "~> 1.2", ">= 1.2.0"
  spec.add_dependency "sparql", "~> 3.3", ">= 3.3.2"
  spec.add_dependency "string_builder", "~> 1.2", ">= 1.2.4"

  spec.add_development_dependency "bundler"
  spec.add_development_dependency "pg"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec-rails"
  spec.add_development_dependency "standard"
  spec.add_development_dependency "yard"

  # Not runtime dependencies. F(x) and pg_cron are mixed into the SAME object as
  # this gem — ActiveRecord::ConnectionAdapters::AbstractAdapter — so "do we
  # collide with them?" is a question only answerable with both installed. See
  # WORKFLOW.md section 2 and spec/pg_ripple/coexistence_spec.rb, which exists
  # because pg_cron once shadowed F(x)'s private resolve_sql_definition and
  # broke every create_function in any app running both.
  spec.add_development_dependency "fx"
  spec.add_development_dependency "pg_cron"
end

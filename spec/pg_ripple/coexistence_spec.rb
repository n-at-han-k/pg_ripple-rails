# frozen_string_literal: true

require "spec_helper"
require "pg_ripple"
require "fx"
require "pg_cron"

# F(x), pg_cron and this gem are mixed into the SAME object —
# ActiveRecord::ConnectionAdapters::AbstractAdapter — and whichever is included
# last wins. pg_cron once lifted F(x)'s private `resolve_sql_definition` under
# F(x)'s own name, one argument shorter, and broke every `create_function` in
# any application running both. "Do we collide?" is a question only answerable
# with all three loaded, which is what this file does.
#
# It is also the reason `create_shape` lives inside `ripple do … end` rather
# than on the adapter: F(x) has no `create_shape` today, but the adapter is a
# shared namespace and the cost of being wrong there is silent breakage in
# someone else's migrations.
RSpec.describe "coexistence with fx and pg_cron" do
  ADAPTER = ActiveRecord::ConnectionAdapters::AbstractAdapter # standard:disable Lint/ConstantDefinitionInBlock

  before do
    PgRipple.load
    Fx.load
    PgCron.load
  end

  around do |example|
    was = ActiveRecord::Migration.verbose
    ActiveRecord::Migration.verbose = false
    example.run
    ActiveRecord::Migration.verbose = was
  end

  def public_and_private_instance_methods(mod)
    (mod.instance_methods(false) + mod.private_instance_methods(false)).to_set
  end

  it "shares no method name with fx or pg_cron, public or private" do
    ours = public_and_private_instance_methods(PgRipple::Statements)

    expect(ours & public_and_private_instance_methods(Fx::Statements)).to be_empty
    expect(ours & public_and_private_instance_methods(PgCron::Statements)).to be_empty
  end

  it "leaves fx owning create_function and create_trigger" do
    expect(ADAPTER.instance_method(:create_function).owner).to eq(Fx::Statements)
    expect(ADAPTER.instance_method(:create_trigger).owner).to eq(Fx::Statements)
  end

  it "leaves pg_cron owning create_cron_job" do
    expect(ADAPTER.instance_method(:create_cron_job).owner).to eq(PgCron::Statements)
  end

  it "puts none of the block's short names on the adapter, where they could shadow" do
    PgRipple::MigrationDsl::Receiver::STATEMENTS.each_key do |short|
      expect(ADAPTER.method_defined?(short)).to be(false), "#{short} is on the shared adapter"
    end
  end

  it "shares no command-recorder name either" do
    ours = public_and_private_instance_methods(PgRipple::CommandRecorder)

    expect(ours & public_and_private_instance_methods(Fx::CommandRecorder)).to be_empty
    expect(ours & public_and_private_instance_methods(PgCron::CommandRecorder)).to be_empty
  end

  # The stronger form, and the one that would have caught `keyword_hash`: not
  # "does it collide with the two gems on this Gemfile" but "could it collide
  # with any gem at all". Both modules are mixed into shared ActiveRecord
  # objects, so every name either of them contributes — private included, since
  # a private method is overwritten just as silently — has to be namespaced.
  # `PgRipple::CommandRecorder::Arguments#keyword_hash` is a different matter:
  # it is private to a `private_constant` class of this gem's own.
  it "namespaces every name it injects into a shared ActiveRecord object" do
    [PgRipple::CommandRecorder, PgRipple::Statements].each do |mod|
      unprefixed = public_and_private_instance_methods(mod).reject { |name| name.to_s.include?("ripple") }

      expect(unprefixed).to be_empty, "#{mod} injects #{unprefixed.to_a.inspect} unnamespaced"
      expect(mod.constants(false)).to be_empty
    end
  end

  # The assertion that matters most: not that the names differ, but that F(x)
  # still WORKS with this gem loaded — in the same migration as a `ripple`
  # block, against a real database.
  #
  # Up only, and not because of anything here: F(x) 0.11.0's
  # `invert_create_function` hands the whole option hash to `drop_function`, so
  # `create_function :name, sql_definition: …` rolls back into
  # `ArgumentError: unknown keyword: :sql_definition` with or without this gem
  # loaded (`fx/command_recorder.rb:19`). That is the failure mode
  # {PgRipple::CommandRecorder}'s `retaining` exists to avoid, and the
  # `ripple` half of this same migration rolls back in
  # `spec/acceptance/ripple_migrations_spec.rb`. The suite's transaction undoes
  # both the function and the prefix.
  it "runs fx's create_function alongside a ripple block", :database do
    migration = Class.new(ActiveRecord::Migration::Current) {
      def change
        create_function :pg_ripple_coexistence_upcase, sql_definition: <<~SQL
          CREATE FUNCTION pg_ripple_coexistence_upcase(text) RETURNS text AS $$
            SELECT upper($1)
          $$ LANGUAGE SQL;
        SQL

        ripple do
          create_prefix :coexist, "https://coexist.example.org/"
        end
      end
    }.new

    ActiveRecord::Base.with_connection do |conn|
      migration.exec_migration(conn, :up)

      expect(conn.select_value("SELECT pg_ripple_coexistence_upcase('abc')")).to eq("ABC")
      expect(PgRipple.database.prefixes.map { |p| p.prefix.to_s }).to include("coexist")
    end
  end
end

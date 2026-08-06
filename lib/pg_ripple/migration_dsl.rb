# frozen_string_literal: true

module PgRipple
  # `ripple do … end`, the short-named migration DSL.
  #
  # The methods mixed into `ActiveRecord::ConnectionAdapters::AbstractAdapter`
  # are `create_ripple_*` and must stay that way: every method on that object is
  # visible to every migration in the host application, so an unprefixed
  # `create_shape` would shadow a same-named method in F(x) or any other
  # migration gem for the whole app. `pg_cron-rails` shipped exactly that bug
  # (`docs/reference-gem-structure.md`).
  #
  # The README's shorter names are still the nicer ones to read, so they live
  # inside a block whose receiver this gem owns. Nothing is added to the
  # adapter, and one name — `ripple` — is added to `ActiveRecord::Migration`.
  #
  #     class AddOrgRules < ActiveRecord::Migration[8.1]
  #       def change
  #         ripple do
  #           create_ruleset :org_rules, version: 1
  #           create_shape   :person_shape
  #         end
  #       end
  #     end
  #
  # Only the object kinds {PgRipple::Statements} actually implements get a short
  # name. A name that raised `NoMethodError` inside a block implying it works
  # would be worse than no name at all.
  module MigrationDsl
    # Runs a block against {PgRipple::MigrationDsl::Receiver}, where the short
    # names are defined.
    #
    # A block taking no argument is `instance_exec`'d, which is what the README
    # shows; a block taking one is passed the receiver instead, for a migration
    # that wants its own `self` back. Either way the receiver forwards anything
    # it does not define to the migration, so `execute`, `say`, `reversible` and
    # the migration's own helper methods still work inside it.
    #
    # @yield [receiver] the short-name receiver, if the block takes an argument
    # @return [Object] the block's value
    def ripple(&block)
      raise ArgumentError, "`ripple` requires a block" if block.nil?

      receiver = PgRipple::MigrationDsl::Receiver.new(self)

      (block.arity <= 0) ? receiver.instance_exec(&block) : block.call(receiver)
    end

    # The receiver `ripple do … end` runs against.
    #
    # Each short name dispatches to its `create_ripple_*` twin, and — this is
    # the part that has to be right — it dispatches through the *migration's*
    # execution strategy rather than straight at a connection. During
    # `db:rollback` a migration's `change` is replayed with
    # `ActiveRecord::Migration::CommandRecorder` standing in for the connection
    # (`ActiveRecord::Migration#revert`), so a receiver that held onto a real
    # adapter would run the migration forwards while Rails believed it was
    # running it backwards. Asking the migration for its strategy on every call
    # means the recorder is what receives the command, {PgRipple::CommandRecorder}
    # inverts it exactly as it does for a directly-written `create_ripple_*`,
    # and `revert_to_version:` keeps working unchanged.
    #
    # The one thing the dispatch deliberately does *not* reuse is
    # `ActiveRecord::Migration#method_missing`, which rewrites the first
    # argument of anything it forwards with `proper_table_name`. That is right
    # for `create_table :people` and wrong for `create_shape :person_shape`: in
    # an engine or an app with `table_name_prefix` set it would silently look
    # for a shape set, a rule set or a URL under a table's name. Being a
    # receiver we own is what makes it possible to skip that, so we skip it —
    # and `say_with_time` is called here instead, so the log line still appears
    # and still names what the migration actually wrote.
    class Receiver
      # Short name => the {PgRipple::Statements} method it stands for.
      #
      # Singular where the README is singular (`create_shape`, `create_ruleset`)
      # even though the underlying statement loads a whole document — the file
      # is the unit the migration names, and these are the names the README
      # published.
      STATEMENTS = {
        create_prefix: :create_ripple_prefix,
        drop_prefix: :drop_ripple_prefix,

        create_shape: :create_ripple_shapes,
        update_shape: :update_ripple_shapes,
        drop_shape: :drop_ripple_shapes,

        create_ruleset: :create_ripple_rules,
        update_ruleset: :update_ripple_rules,
        drop_ruleset: :drop_ripple_rules,
        disable_ruleset: :disable_ripple_rules,
        enable_ruleset: :enable_ripple_rules,

        create_sparql_view: :create_ripple_sparql_view,
        update_sparql_view: :update_ripple_sparql_view,
        drop_sparql_view: :drop_ripple_sparql_view,

        create_endpoint: :create_ripple_endpoint,
        drop_endpoint: :drop_ripple_endpoint
      }.freeze

      # @param migration [ActiveRecord::Migration]
      def initialize(migration)
        @migration = migration
      end

      STATEMENTS.each do |short, long|
        # `...` rather than `define_method(*args, **kwargs)`: every statement
        # here takes keywords, the recorder that may receive them is
        # `ruby2_keywords`, and forwarding is the one construct that cannot get
        # that wrong.
        class_eval <<~RUBY, __FILE__, __LINE__ + 1
          def #{short}(...)
            ripple_dispatch(:#{short}, :#{long}, ...)
          end
        RUBY
      end

      # Anything that is not a pg_ripple statement is the migration's business:
      # `execute`, `create_table`, `reversible`, `say`, and whatever the
      # migration defines itself. Forwarded rather than swallowed, so a block
      # reads like the rest of `change`.
      def method_missing(name, ...)
        return super unless @migration.respond_to?(name, true)

        @migration.__send__(name, ...)
      end

      def respond_to_missing?(name, include_private = false)
        @migration.respond_to?(name, include_private) || super
      end

      def inspect
        "#<PgRipple::MigrationDsl::Receiver #{@migration.class.name}>"
      end

      private

      def ripple_dispatch(short, long, *args, &block)
        @migration.say_with_time("#{short}(#{format_ripple_arguments(args)})") do
          ripple_execution_strategy.public_send(long, *args, &block)
        end
      end
      ruby2_keywords :ripple_dispatch

      # `execution_strategy` is how a migration reaches its connection in Rails
      # 7.1 and later, and it is what honours a host application's
      # `ActiveRecord.migration_strategy`. The fallback is for a strategy-less
      # migration object, where the connection — recorder or adapter — is the
      # thing itself.
      def ripple_execution_strategy
        return @migration.execution_strategy if @migration.respond_to?(:execution_strategy)

        @migration.connection
      end

      # `create_shape(:person, version: 2)` rather than
      # `create_shape(:person, {version: 2})`. Rails formats its own log line
      # this way; its `format_arguments` is private, so this is four lines of
      # our own rather than a private API we would have to track.
      def format_ripple_arguments(args)
        args = args.dup
        options = args.pop if args.last.is_a?(Hash)

        formatted = args.map(&:inspect)
        formatted += options.map { |key, value| "#{key}: #{value.inspect}" } if options

        formatted.join(", ")
      end
    end
  end
end

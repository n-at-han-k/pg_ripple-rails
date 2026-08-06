# frozen_string_literal: true

module PgRipple
  # Makes {PgRipple::Statements} reversible, following F(x)'s CommandRecorder.
  #
  # Two thirds of this file is `record` plus `ruby2_keywords`, exactly as in
  # F(x). The interesting part is the inversion of a drop or an update, which is
  # only meaningful if the migration said what to go back to — otherwise a
  # rollback either fails or, worse, leaves the object missing. For the three
  # document kinds that is `revert_to_version:`, swapped in as `version:`. For
  # prefixes and endpoints, which have no version because they have no file, it
  # is `revert_to_expansion:` and `revert_to:` respectively.
  #
  # Method names carry `ripple_` for the same reason the statements do, though
  # the stakes are lower here: CommandRecorder is a different object from
  # AbstractAdapter, so a collision with F(x) would have to be a collision on
  # the DSL name itself.
  module CommandRecorder
    def create_ripple_prefix(*args, &block)
      record(:create_ripple_prefix, args, &block)
    end
    ruby2_keywords :create_ripple_prefix

    def drop_ripple_prefix(*args, &block)
      record(:drop_ripple_prefix, args, &block)
    end
    ruby2_keywords :drop_ripple_prefix

    # A prefix takes two positional arguments and no options, so the inversion
    # is written out rather than run through {Arguments}: the expansion that
    # created the prefix becomes the `revert_to_expansion` that would restore
    # it, which leaves the generated drop reversible in its own right.
    def invert_create_ripple_prefix(args)
      prefix, expansion = args

      [:drop_ripple_prefix, [prefix, ripple_keyword_hash(revert_to_expansion: expansion)]]
    end

    def invert_drop_ripple_prefix(args)
      prefix, options = args
      expansion = (options || {})[:revert_to_expansion]

      if expansion.nil?
        raise ActiveRecord::IrreversibleMigration,
          format(MESSAGE_IRREVERSIBLE, :drop_ripple_prefix, :revert_to_expansion)
      end

      [:create_ripple_prefix, [prefix, expansion]]
    end

    def create_ripple_shapes(*args, &block)
      record(:create_ripple_shapes, args, &block)
    end
    ruby2_keywords :create_ripple_shapes

    def update_ripple_shapes(*args, &block)
      record(:update_ripple_shapes, args, &block)
    end
    ruby2_keywords :update_ripple_shapes

    def drop_ripple_shapes(*args, &block)
      record(:drop_ripple_shapes, args, &block)
    end
    ruby2_keywords :drop_ripple_shapes

    # Dropping a shape set needs the file that named its shapes, so the
    # version — or the inline definition — is carried across. Everything else
    # is dropped: `drop_ripple_shapes` takes nothing else, and passing an
    # option a method does not accept is how F(x)'s own `invert_create_function`
    # trips over `create_function :name, version: 2`.
    def invert_create_ripple_shapes(args)
      [:drop_ripple_shapes, Arguments.new(args).retaining(:version, :definition).to_a]
    end

    def invert_drop_ripple_shapes(args)
      perform_ripple_inversion(:drop_ripple_shapes, :create_ripple_shapes, args)
    end

    # The one inversion that does not follow F(x). F(x) sets `version:` from
    # `revert_to_version:` and deletes the latter; here the two are EXCHANGED,
    # so the rolled-back update still knows which version it is coming from.
    # {PgRipple::Statements#update_ripple_shapes} needs that to sweep orphans:
    # rolling v2 back to v1 has to drop the shapes v2 introduced, and the only
    # record of what those were is v2's file. Deleting `revert_to_version` would
    # leave them loaded and validating after the rollback claimed to have
    # removed them.
    def invert_update_ripple_shapes(args)
      perform_ripple_inversion(:update_ripple_shapes, :update_ripple_shapes, args, exchange: true)
    end

    def create_ripple_rules(*args, &block)
      record(:create_ripple_rules, args, &block)
    end
    ruby2_keywords :create_ripple_rules

    def update_ripple_rules(*args, &block)
      record(:update_ripple_rules, args, &block)
    end
    ruby2_keywords :update_ripple_rules

    def drop_ripple_rules(*args, &block)
      record(:drop_ripple_rules, args, &block)
    end
    ruby2_keywords :drop_ripple_rules

    # A rule set is dropped by name alone, so no option survives the inversion.
    def invert_create_ripple_rules(args)
      [:drop_ripple_rules, Arguments.new(args).retaining.to_a]
    end

    def invert_drop_ripple_rules(args)
      perform_ripple_inversion(:drop_ripple_rules, :create_ripple_rules, args)
    end

    def invert_update_ripple_rules(args)
      perform_ripple_inversion(:update_ripple_rules, :update_ripple_rules, args)
    end

    def disable_ripple_rules(*args, &block)
      record(:disable_ripple_rules, args, &block)
    end
    ruby2_keywords :disable_ripple_rules

    def enable_ripple_rules(*args, &block)
      record(:enable_ripple_rules, args, &block)
    end
    ruby2_keywords :enable_ripple_rules

    # The only pair here that inverts into each other, and the only inversion
    # that needs no `revert_to_*`: both take a name and nothing else, and each
    # is the other's exact opposite. Note that neither restores inferences —
    # disabling does not retract them and enabling does not re-derive them
    # until the next `infer()`.
    def invert_disable_ripple_rules(args)
      [:enable_ripple_rules, args]
    end

    def invert_enable_ripple_rules(args)
      [:disable_ripple_rules, args]
    end

    def create_ripple_sparql_view(*args, &block)
      record(:create_ripple_sparql_view, args, &block)
    end
    ruby2_keywords :create_ripple_sparql_view

    def update_ripple_sparql_view(*args, &block)
      record(:update_ripple_sparql_view, args, &block)
    end
    ruby2_keywords :update_ripple_sparql_view

    def drop_ripple_sparql_view(*args, &block)
      record(:drop_ripple_sparql_view, args, &block)
    end
    ruby2_keywords :drop_ripple_sparql_view

    # Like a rule set, a view is dropped by name alone — `schedule`, `decode`
    # and `immediate` mean nothing to the drop and would be a wrong-number-of-
    # arguments error if passed on.
    def invert_create_ripple_sparql_view(args)
      [:drop_ripple_sparql_view, Arguments.new(args).retaining.to_a]
    end

    def invert_drop_ripple_sparql_view(args)
      perform_ripple_inversion(:drop_ripple_sparql_view, :create_ripple_sparql_view, args)
    end

    # `schedule` and `decode` ride along unchanged, which is right for a
    # rollback that only changes the query: the version moves, the refresh
    # behaviour does not. A migration that changed the schedule too must say so
    # on both sides.
    def invert_update_ripple_sparql_view(args)
      perform_ripple_inversion(:update_ripple_sparql_view, :update_ripple_sparql_view, args)
    end

    def create_ripple_endpoint(*args, &block)
      record(:create_ripple_endpoint, args, &block)
    end
    ruby2_keywords :create_ripple_endpoint

    def drop_ripple_endpoint(*args, &block)
      record(:drop_ripple_endpoint, args, &block)
    end
    ruby2_keywords :drop_ripple_endpoint

    # An endpoint has no version, so its whole option hash is what a rollback
    # would need to restore it, and that hash is what `revert_to:` carries. An
    # endpoint created with no options at all inverts to `revert_to: {}`, which
    # is deliberately distinct from `revert_to: nil` — the first restores a bare
    # endpoint, the second is irreversible.
    def invert_create_ripple_endpoint(args)
      arguments = Arguments.new(args)

      [:drop_ripple_endpoint, [arguments.object, ripple_keyword_hash(revert_to: arguments.options)]]
    end

    def invert_drop_ripple_endpoint(args)
      url, options = args
      revert_to = (options || {})[:revert_to]

      if revert_to.nil?
        raise ActiveRecord::IrreversibleMigration,
          format(MESSAGE_IRREVERSIBLE, :drop_ripple_endpoint, :revert_to)
      end

      [:create_ripple_endpoint, [url, ripple_keyword_hash(revert_to.dup)]]
    end

    private

    MESSAGE_IRREVERSIBLE = "`%s` is reversible only if given a `%s`"
    private_constant :MESSAGE_IRREVERSIBLE

    # `command` is what the migration wrote and `method` is what the rollback
    # will run; they differ for a drop. F(x) has only the second and so reports
    # a rollback of `drop_function` as `create_function` being irreversible,
    # which sends the reader to the wrong line of the migration.
    def perform_ripple_inversion(command, method, args, exchange: false)
      arguments = Arguments.new(args)

      if arguments.revert_to_version.nil?
        raise ActiveRecord::IrreversibleMigration,
          format(MESSAGE_IRREVERSIBLE, command, :revert_to_version)
      end

      inverted = exchange ? arguments.exchange_version : arguments.invert_version

      [method, inverted.to_a]
    end

    # Prefixed like everything else this module injects.
    #
    # This module is `include`d into the *shared*
    # `ActiveRecord::Migration::CommandRecorder`, alongside whatever every
    # other extension gem put there, so an unprefixed name here is a silent
    # collision waiting for the gem that defines the same one. The nested
    # {Arguments#keyword_hash} is a different matter: it is private to a
    # `private_constant` class of this gem's own.
    def ripple_keyword_hash(hash)
      Hash.ruby2_keywords_hash(hash)
    end

    # F(x)'s Arguments, with `object` in place of `function` — the first
    # positional is a prefix, a shape set, a rule set, a view or a URL — and one
    # addition, {#retaining}, for the inversions that must narrow the option
    # hash rather than pass it through.
    class Arguments
      def initialize(args)
        @args = args.freeze
      end

      def object
        args.fetch(0)
      end

      def options
        @options ||= args.fetch(1, {}).dup
      end

      def version
        options.fetch(:version, nil)
      end

      def revert_to_version
        options.fetch(:revert_to_version, nil)
      end

      # `version:` becomes `revert_to_version:`, and `revert_to_version:` is
      # dropped. F(x)'s behaviour, and the right one wherever the inverted
      # command has no reason to look back at where it came from.
      def invert_version
        self.class.new([object, keyword_hash(options_for_revert)])
      end

      # `version:` and `revert_to_version:` trade places, leaving the inverted
      # command reversible in its turn. See
      # {PgRipple::CommandRecorder#invert_update_ripple_shapes} for why one
      # statement needs this.
      def exchange_version
        exchanged = options.clone.tap do |opts|
          opts[:version] = revert_to_version
          opts[:revert_to_version] = version
        end

        self.class.new([object, keyword_hash(exchanged)])
      end

      # A copy carrying only the named options, and no options at all when
      # given none.
      def retaining(*keys)
        self.class.new([object, keyword_hash(options.slice(*keys))])
      end

      def to_a
        return [object] if args.length > 1 && options.empty?

        args.to_a
      end

      private

      attr_reader :args

      def options_for_revert
        options.clone.tap do |revert_options|
          revert_options[:version] = revert_to_version
          revert_options.delete(:revert_to_version)
        end
      end

      def keyword_hash(hash)
        Hash.ruby2_keywords_hash(hash)
      end
    end
    private_constant :Arguments
  end
end

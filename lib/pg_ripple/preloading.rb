# frozen_string_literal: true

require "pg_ripple/preloader"

module PgRipple
  # `graph_includes` — the eager-load side of a graph association.
  #
  #     Person.where(role: "manager").graph_includes(:reports, :employer)
  #
  # One `CONSTRUCT` for the whole page, shaped by a JSON-LD frame, plus one SQL
  # query per target class. Afterwards `person.reports` is a *loaded* relation:
  # it queries nothing, which is the entire point and is what
  # `spec/acceptance/preloading_spec.rb` asserts by counting queries rather than
  # by checking that the records come back.
  #
  # ### Where the method lives
  #
  # On the model's own relation delegate classes, not on
  # `ActiveRecord::Relation`. `Person.where(…)` has returned a
  # `Person::ActiveRecord_Relation` since Rails 4, and
  # {ActiveRecord::Delegation::ClassMethods#relation_delegate_class} is the
  # supported way to reach it. A gem that reopened `ActiveRecord::Relation`
  # would put `graph_includes` on every relation in the application, including
  # the models that have no graph mapping and could only answer with a
  # `NoMethodError` from somewhere further in.
  #
  # ### Where the preload runs
  #
  # In `#exec_queries`, which is where ActiveRecord runs its own preloaders —
  # after the records exist and before `#load` returns them. So it fires for
  # `to_a`, `each`, `first`, `find_each` and Kaminari's `#page`, once, and never
  # for a relation nobody loaded.
  module Preloading
    # The relation classes a model's `graph_includes` has to reach.
    #
    # `AssociationRelation` and `CollectionProxy` are separate delegate classes
    # from `Relation`, so `account.people.graph_includes(:reports)` would
    # otherwise be a `NoMethodError`.
    #
    # Named lazily, not in the class body: `ActiveRecord::Relation` is
    # mid-autoload while this file is being required from `pg_ripple.rb`.
    #
    # @return [Array<Class>]
    def self.relation_classes
      [
        ActiveRecord::Relation,
        ActiveRecord::AssociationRelation,
        ActiveRecord::Associations::CollectionProxy
      ]
    end

    # @param model [Class] an ActiveRecord model including {PgRipple::Node}
    # @return [void]
    def self.install(model)
      relation_classes.each do |kind|
        model.relation_delegate_class(kind).include(RelationMethods)
      end
    end

    # `graph_includes` and the hook that acts on it.
    module RelationMethods
      # The association names this relation will preload.
      #
      # @return [Array<Symbol>]
      def pg_ripple_graph_includes_values
        @pg_ripple_graph_includes_values || []
      end

      attr_writer :pg_ripple_graph_includes_values

      # Eager-loads graph associations for the whole page.
      #
      #     Person.where(role: "manager").graph_includes(:reports, :employer)
      #
      # Composes in both directions with everything else: ordinary `includes`,
      # `where`, `order`, `limit`, and the lateral-join relation `Person.graph`
      # builds.
      #
      # @param names [Symbol]
      # @return [ActiveRecord::Relation]
      # @raise [ArgumentError] for a name no `graph_has_many`/`graph_has_one`
      #   declared — checked here, where the backtrace still points at the
      #   caller, rather than when the relation is eventually loaded
      def graph_includes(*names)
        names = names.flatten.map(&:to_sym)
        names.each { |name| pg_ripple_graph_association!(name) }

        spawn.tap do |relation|
          relation.pg_ripple_graph_includes_values = pg_ripple_graph_includes_values | names
        end
      end

      # Fills this relation with records that are already in hand.
      #
      # `ActiveRecord::Relation#load_records` is *protected* — reachable from
      # another relation, not from the record that owns one — so this is the
      # doorway rather than a `send`. It is what makes the reader after a
      # preload a loaded relation and not an array: `person.reports.size` costs
      # nothing and `person.reports.where(…)` still spawns and queries, which
      # is exactly what a loaded `has_many` does.
      #
      # @api private
      # @param records [Array<ActiveRecord::Base>]
      # @return [self]
      def pg_ripple_load_records(records)
        load_records(records)
        self
      end

      # Carried across `#spawn` by hand — belt and braces, and said plainly.
      #
      # ActiveRecord copies its own `*_values` onto a spawned relation from a
      # list it owns and knows nothing about this one. It happens that on
      # ActiveRecord 8.1 every `#spawn` path this gem could find is a `clone`,
      # which copies the ivar anyway: removing this method leaves the whole
      # suite green, including a `graph_includes(...).where(...)` inside a
      # `scoping` block, which is the one path where `#spawn` can return a
      # fresh `klass.all` instead. Nothing documents that, and the failure mode
      # if it ever stops being true is a preload that silently does not happen
      # — the worst possible failure for a method whose only job is to stop a
      # query later. So the carry is explicit and the measurement is here in
      # the comment rather than dressed up as a spec that cannot fail.
      def spawn
        super.tap { |relation| relation.pg_ripple_graph_includes_values = pg_ripple_graph_includes_values }
      end

      # `#merge` is the case {#spawn} cannot cover, and the likeliest way to
      # lose a preload in a real application.
      #
      # `ActiveRecord::SpawnMethods#merge` spawns the *receiver* and then folds
      # the argument in through `Relation::Merger`, which copies the values
      # ActiveRecord knows about and nothing else. So the receiver's includes
      # survived and the argument's were dropped, measured:
      #
      #     Person.graph_includes(:reports).merge(Person.where(active: true))
      #       # => [:reports]
      #     Person.where(active: true).merge(Person.graph_includes(:reports))
      #       # => []   ← the N+1, back, with no error
      #
      # The second line is how Rails composes named scopes, how a `has_many`
      # `scope:` block is applied, and how Ransack and ActiveAdmin build
      # relations, so it is the everyday spelling and not a corner. Nothing
      # surfaced it either: the reader answered correctly, one traversal per
      # record, and only `PgRipple.configuration.strict_loading` — off by
      # default — turned it into an error.
      #
      # Overridden on `#merge!` rather than `#merge` because `#merge` is also
      # reached with a Hash and with a Proc, and `#merge!` is the one place the
      # argument itself is folded in.
      #
      # @param other [ActiveRecord::Relation, Hash, Proc]
      # @return [self]
      def merge!(other, *rest)
        super.tap do
          next unless other.respond_to?(:pg_ripple_graph_includes_values)

          self.pg_ripple_graph_includes_values =
            pg_ripple_graph_includes_values | other.pg_ripple_graph_includes_values
        end
      end

      private

      def exec_queries(&block)
        super.tap do |records|
          next if pg_ripple_graph_includes_values.empty?

          PgRipple::Preloader.call(records, pg_ripple_graph_includes_values, model: klass)
        end
      end

      def pg_ripple_graph_association!(name)
        return if klass.respond_to?(:graph_associations) && klass.graph_associations.key?(name)

        raise ArgumentError,
          "#{klass.name} has no graph association #{name.inspect}; " \
          "declared: #{(klass.try(:graph_associations) || {}).keys.map(&:inspect).join(", ")}"
      end
    end
  end
end

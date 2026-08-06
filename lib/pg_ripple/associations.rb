# frozen_string_literal: true

require "active_support/concern"
require "rdf"

require "pg_ripple/path"
require "pg_ripple/persistence"
require "pg_ripple/preloading"
require "pg_ripple/query"
require "pg_ripple/relation"
require "pg_ripple/term"

module PgRipple
  # `graph_has_many` and `graph_has_one`: associations with no foreign key.
  #
  # Mixed into every model that includes {PgRipple::Node}. The reader returns a
  # real `ActiveRecord::Relation` — not a proxy, not an array — so
  # `alice.network.where(active: true).includes(:account).page(2)` is ordinary
  # ActiveRecord all the way down and Kaminari, Ransack and ActiveAdmin need to
  # know nothing about any of this.
  #
  # There being no foreign key is what makes direction a property of the query
  # rather than of the schema: `belongs_to` is `~` on the path.
  #
  #     graph_has_many :friends,    predicate: foaf.knows
  #     graph_has_many :network,    path: +foaf.knows
  #     graph_has_one  :manager,    path: ~ex.manages
  #     graph_has_many :colleagues, path: ~ex.worksAt / ex.worksAt
  module Associations
    extend ActiveSupport::Concern

    included do
      # `graph_includes` on this model's relations.
      PgRipple::Preloading.install(self)
    end

    # What one `graph_has_many` or `graph_has_one` declared.
    class Definition
      # @return [Symbol]
      attr_reader :name

      # @return [PgRipple::Path]
      attr_reader :path

      # @return [Symbol] `:many` or `:one`
      attr_reader :arity

      # @param name [Symbol]
      # @param owner [Class] the declaring model
      # @param predicate [RDF::URI, PgRipple::Path, nil]
      # @param path [PgRipple::Path, RDF::URI, nil]
      # @param class_name [String, nil] the target model. Defaults to the
      #   association name's classification, as ActiveRecord's does.
      # @param arity [Symbol]
      # @param graph_name [String, RDF::URI, nil]
      def initialize(name, owner:, predicate: nil, path: nil, class_name: nil, arity: :many, graph_name: :configured)
        if predicate.nil? == path.nil?
          raise ArgumentError,
            "graph_has_#{arity} #{name.inspect} needs exactly one of predicate: or path:"
        end

        @name = name.to_sym
        @owner = owner
        @path = PgRipple::Path.coerce(predicate || path)
        @class_name = class_name&.to_s
        @arity = arity
        @graph_name = graph_name
      end

      # @return [Class] the model on the far end
      def target
        @target ||= (@class_name || name.to_s.classify).constantize
      end

      # The named graph this association traverses, always as an {RDF::URI}.
      #
      # Coerced here rather than at each use, for two reasons measured on a
      # live database (`docs/spec-corrections.md` §21):
      #
      # * Every other entry point in the gem takes a graph as a `String` —
      #   `PgRipple.repository(graph_name: "https://…")`, `Query.new`,
      #   `Relation#in_graph` — and the README's initializer writes
      #   `c.default_graph` as one. The lazy read went through
      #   {PgRipple::Query}, which coerces; the preload went through
      #   {PgRipple::Preloader.construct}, which hands the value straight to
      #   {PgRipple::Term.sparql} and raises `ArgumentError` for anything that
      #   is not already an `RDF::Term`. So `graph_has_many …, graph_name:
      #   "https://…"` read fine lazily and exploded under `graph_includes`.
      # * {PgRipple::Preloader} groups definitions by this value to decide how
      #   many `CONSTRUCT`s to run. A `String` and an equal `RDF::URI` are
      #   different hash keys, so two associations naming the same graph two
      #   ways were split into two round trips.
      #
      # `Term.graph_argument` first, so a value written with the angle brackets
      # it wears in N-Triples means the same graph as one without.
      #
      # @return [RDF::URI, nil] nil for the default graph
      def graph_name
        value = (@graph_name == :configured) ? PgRipple.configuration.default_graph : @graph_name
        return nil if value.nil?

        RDF::URI(PgRipple::Term.graph_argument(value))
      end

      # The traversal, from one record.
      #
      # `LIMIT 1` is *not* pushed into a `graph_has_one`'s SPARQL even though
      # only one row comes back: the one solution the store would return first
      # need not be the one with a row in the target table, and a `graph_has_one`
      # that returned nil because it truncated to the wrong subject would be a
      # very quiet bug.
      #
      # @param record [ActiveRecord::Base]
      # @return [ActiveRecord::Relation]
      def scope_for(record)
        query = PgRipple::Query.new(graph_name: graph_name)
        query.traverse(from: subject_for(record), path: path)

        PgRipple::Relation.attach(target.all, query.to_s).extending(extension)
      end

      # The single predicate `<<` and `#delete` write, if there is one.
      #
      # A multi-hop or transitive path has no such thing: `alice.network << bob`
      # is asking to assert `foaf:knows+`, and there is no triple that means
      # that. {PgRipple::Path#to_term} is what refuses it, and the refusal is
      # the honest answer rather than a guess at which hop was meant.
      #
      # @return [RDF::URI]
      # @raise [PgRipple::NotAPredicate]
      def predicate
        path.to_term
      end

      # @param record [ActiveRecord::Base]
      # @return [RDF::URI]
      def subject_for(record)
        iri = record.iri
        if iri.blank?
          raise PgRipple::IriError,
            "#{record.class.name}##{name} needs a saved record: an unsaved one has no subject IRI"
        end

        RDF::URI(iri)
      end

      # @param record [ActiveRecord::Base]
      # @param others [Array<ActiveRecord::Base>]
      # @return [Array<RDF::Statement>]
      def statements_for(record, others)
        subject = subject_for(record)

        others.map do |other|
          RDF::Statement.new(subject, predicate, subject_for_target(other), graph_name: graph_name)
        end
      end

      # The module every relation this association builds is extended with.
      #
      # One module per association rather than one per read: an anonymous
      # module per call would be a fresh constant-less class hierarchy on every
      # `alice.friends`, and would invalidate Ruby's method cache each time.
      #
      # @return [Module]
      def extension
        @extension ||= CollectionMethods.for(self)
      end

      private

      def subject_for_target(other)
        unless other.is_a?(target)
          raise ArgumentError, "#{name} holds #{target.name}, not #{other.class.name}"
        end

        subject_for(other)
      end
    end

    # `<<` and `#delete` on the relation a `graph_has_many` returns.
    #
    # These are the two operations with no SQL counterpart at all — there is no
    # join row to insert — so they go straight to SPARQL 1.1 Update, inside the
    # record's own transaction. `pg_ripple.sparql_update()` runs in the caller's
    # transaction, so an `ActiveRecord::Rollback` after one takes the edge with
    # it and no `after_commit` compensation is needed
    # (`docs/probe-lateral-join.md` §e).
    module CollectionMethods
      # Builds the extension module for one association.
      #
      # @param definition [PgRipple::Associations::Definition]
      # @return [Module]
      def self.for(definition)
        Module.new do
          define_method(:pg_ripple_association) { definition }
          include CollectionMethods
        end
      end

      # The record the traversal starts from.
      #
      # Carried across `#spawn` by hand, because ActiveRecord copies its own
      # values onto a spawned relation and knows nothing about this one. Without
      # it `alice.friends.where(active: true) << bob` would raise `NoMethodError`
      # from inside the extension module, which is a worse error than the one
      # below.
      attr_accessor :pg_ripple_owner

      def spawn
        super.tap { |relation| relation.pg_ripple_owner = pg_ripple_owner }
      end

      # Asserts an edge from the owner to each record.
      #
      #     alice.friends << bob   # INSERT DATA { <alice> foaf:knows <bob> }
      #
      # @param records [ActiveRecord::Base]
      # @return [self]
      def <<(*records)
        PgRipple::Persistence.assert(
          pg_ripple_association.statements_for(pg_ripple_require_owner, records.flatten),
          repository: pg_ripple_repository
        )
        pg_ripple_reset
        self
      end
      alias_method :push, :<<
      alias_method :concat, :<<

      # Retracts the edge from the owner to each record.
      #
      #     alice.friends.delete(bob)   # DELETE DATA { <alice> foaf:knows <bob> }
      #
      # @param records [ActiveRecord::Base]
      # @return [Array<ActiveRecord::Base>] the records, as ActiveRecord's does
      def delete(*records)
        records = records.flatten
        PgRipple::Persistence.retract(
          pg_ripple_association.statements_for(pg_ripple_require_owner, records),
          repository: pg_ripple_repository
        )
        pg_ripple_reset
        records
      end

      # Creates a record **and** asserts the edge to it.
      #
      # Without this, `#create!` is the plain relation's: it inserts a row,
      # writes no triple, and hands back a record the association does not
      # contain — `alice.friends.create!(name: "New")` returned the record and
      # `alice.friends` stayed empty. On a `has_many` that call links what it
      # creates, and there is no reason a graph association should be the one
      # collection in ActiveRecord where it silently does not.
      #
      # The edge is written after the insert because it needs the record's
      # subject IRI, and {PgRipple::Node} mints that on create. A `#create`
      # whose validations failed is left unlinked, since there is nothing
      # persisted to link to.
      #
      # @return [ActiveRecord::Base, Array<ActiveRecord::Base>]
      def create(attributes = nil, &block)
        # The array form recurses back through this method, so every element is
        # already linked by the time the outer call sees them.
        return super if attributes.is_a?(Array)

        pg_ripple_link(super)
      end

      # @return [ActiveRecord::Base, Array<ActiveRecord::Base>]
      def create!(attributes = nil, &block)
        return super if attributes.is_a?(Array)

        pg_ripple_link(super)
      end

      # There is no such thing as an unsaved edge.
      #
      # `has_many#build` links in memory by setting a foreign key. A graph
      # association has no foreign key and no in-memory representation at all —
      # the edge is a triple about two subject IRIs, and an unsaved record has
      # no IRI to be one of them. Returning an unlinked record (which is what
      # the plain relation's `#build` did) is the silent version of this error.
      #
      # @raise [NotImplementedError]
      def new(*, **, &)
        raise NotImplementedError,
          "#{pg_ripple_association.name} cannot build an unsaved record: a graph edge is a triple " \
          "between two subject IRIs and an unsaved record has none. Use `create!` or " \
          "`association << record`."
      end
      alias_method :build, :new

      private

      # Resets this relation *and* the owner's preloaded copy of it.
      #
      # `alice.reports << bob` after a `graph_includes(:reports)` has to
      # invalidate the array the preload handed the owner, or the next
      # `alice.reports` answers from before the write.
      def pg_ripple_reset
        reset
        pg_ripple_owner&.reset_graph_association(pg_ripple_association.name)
      end

      # Asserts the edge to everything that got persisted.
      def pg_ripple_link(created)
        records = Array(created).select(&:persisted?)
        self << records unless records.empty?

        created
      end

      def pg_ripple_repository
        PgRipple.repository(graph_name: pg_ripple_association.graph_name)
      end

      def pg_ripple_require_owner
        pg_ripple_owner || raise(ArgumentError,
          "#{pg_ripple_association.name} can only be written through the association itself")
      end
    end

    # Whether `graph_includes` has already filled this association in.
    #
    # @param name [Symbol]
    # @return [Boolean]
    def graph_association_loaded?(name)
      pg_ripple_loaded_graph_associations.key?(name.to_sym)
    end

    # Hands one record its slice of a preload.
    #
    # @api private
    # @param name [Symbol]
    # @param records [Array<ActiveRecord::Base>]
    # @return [Array<ActiveRecord::Base>]
    def pg_ripple_graph_association_loaded(name, records)
      pg_ripple_loaded_graph_associations[name.to_sym] = records.freeze
    end

    # Forgets a preloaded association, so the next read goes to the store.
    #
    # Called by `<<` and `#delete`: an edge written through a preloaded
    # association would otherwise leave the owner answering from a cache that
    # predates the write, which is the one thing a preload must never do.
    #
    # @param name [Symbol, nil] nil for all of them
    # @return [void]
    def reset_graph_association(name = nil)
      if name.nil?
        pg_ripple_loaded_graph_associations.clear
      else
        pg_ripple_loaded_graph_associations.delete(name.to_sym)
      end
    end

    # Discards preloaded graph associations along with the row.
    #
    # @return [self]
    def reload(...)
      reset_graph_association
      super
    end

    # Whether reading an un-preloaded graph association should raise.
    #
    # Both switches, the same way ActiveRecord reads its own: the global
    # {PgRipple::Configuration#strict_loading} the README's initializer sets,
    # and the per-record/per-relation `strict_loading` flag ActiveRecord
    # already carries — `Person.strict_loading.find(1)` means the same thing
    # about a graph association as it does about a `has_many`.
    #
    # @return [Boolean]
    def pg_ripple_strict_loading?
      return true if PgRipple.configuration.strict_loading
      return false unless respond_to?(:strict_loading?)

      strict_loading?
    end

    private

    def pg_ripple_loaded_graph_associations
      @pg_ripple_loaded_graph_associations ||= {}
    end

    # The reader `graph_has_many`/`graph_has_one` generates.
    #
    # Preloaded, it is the same relation object as ever with its records
    # already in it (`ActiveRecord::Relation#load_records`), so
    # `person.reports.map(&:name)` and `person.reports.size` query nothing
    # while `person.reports.where(active: true)` still spawns and queries —
    # exactly what a loaded `has_many` does.
    def pg_ripple_read_graph_association(definition)
      unless graph_association_loaded?(definition.name)
        pg_ripple_strict_loading_violation!(definition) if pg_ripple_strict_loading?

        relation = pg_ripple_graph_relation(definition)
        return (definition.arity == :one) ? relation.first : relation
      end

      loaded = pg_ripple_loaded_graph_associations.fetch(definition.name)
      return loaded.first if definition.arity == :one

      pg_ripple_graph_relation(definition).pg_ripple_load_records(loaded.dup)
    end

    def pg_ripple_graph_relation(definition)
      public_send(:"#{definition.name}_relation")
    end

    def pg_ripple_strict_loading_violation!(definition)
      raise ActiveRecord::StrictLoadingViolationError,
        "`#{self.class.name}##{definition.name}` is a graph association that was not preloaded. " \
        "Load it with `graph_includes(:#{definition.name})`, or query it explicitly with " \
        "`#{definition.name}_relation`."
    end

    class_methods do
      # `Person.graph_includes(:reports)` — the class-level entry point.
      #
      # @param names [Symbol]
      # @return [ActiveRecord::Relation]
      def graph_includes(*names)
        all.graph_includes(*names)
      end

      # @return [Hash{Symbol => PgRipple::Associations::Definition}]
      def graph_associations
        @graph_associations ||= superclass.respond_to?(:graph_associations) ? superclass.graph_associations.dup : {}
      end

      # A collection reached by a property path rather than a foreign key.
      #
      # @param name [Symbol]
      # @param predicate [RDF::URI, PgRipple::Path, nil] a single predicate
      # @param path [PgRipple::Path, RDF::URI, nil] any property path
      # @param class_name [String, nil]
      # @param graph_name [String, RDF::URI, nil] a named graph to traverse in
      # @return [PgRipple::Associations::Definition]
      def graph_has_many(name, predicate: nil, path: nil, class_name: nil, graph_name: :configured)
        define_graph_association(
          name, predicate: predicate, path: path, class_name: class_name,
          arity: :many, graph_name: graph_name
        )
      end

      # The at-most-one version.
      #
      # The reader returns the **record**, not a relation, because
      # `alice.manager.name` is what a `has_one` means everywhere else in
      # ActiveRecord and a relation that had to be `.first`ed would be a
      # `has_many` with a singular name. The relation is still there, as
      # `#<name>_relation`, and it is what `graph_has_many` returns.
      #
      # @return [PgRipple::Associations::Definition]
      def graph_has_one(name, predicate: nil, path: nil, class_name: nil, graph_name: :configured)
        define_graph_association(
          name, predicate: predicate, path: path, class_name: class_name,
          arity: :one, graph_name: graph_name
        )
      end

      # `Person.graph` — the model-side query entry point.
      #
      # {PgRipple::Node#graph} defers to this when it is called with neither
      # options nor a block.
      #
      # @return [PgRipple::Relation]
      def graph_relation
        PgRipple::Relation.new(self, scope: all)
      end

      private

      def define_graph_association(name, arity:, **options)
        definition = Definition.new(name, owner: self, arity: arity, **options)
        graph_associations[definition.name] = definition

        # Always a fresh, unloaded relation, even when the association has been
        # preloaded and even under `strict_loading`. It is the documented way
        # to say "query this one anyway", and a method whose whole purpose is
        # to run the query cannot be the method that refuses to.
        generated_graph_association_methods.define_method(:"#{name}_relation") do
          definition.scope_for(self).tap { |relation| relation.pg_ripple_owner = self }
        end

        generated_graph_association_methods.define_method(name) do
          pg_ripple_read_graph_association(definition)
        end

        definition
      end

      def generated_graph_association_methods
        @generated_graph_association_methods ||= begin
          mod = const_set(:GeneratedGraphAssociationMethods, Module.new)
          include mod

          mod
        end
      end
    end
  end
end

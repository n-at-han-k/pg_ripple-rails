# frozen_string_literal: true

require "active_triples"

require "pg_ripple/associations"
require "pg_ripple/persistence/diff_strategy"

module PgRipple
  # Raised when a graph property is addressed by a name nothing declared.
  #
  # The point of the schema living in Ruby is that `Person.graph.where(rle: …)`
  # can fail rather than return zero rows against a schemaless store — see
  # "Where the abstraction leaks" in the README. A {NameError} so that `#name`
  # carries the offending term.
  class UnknownProperty < NameError; end

  # Raised when a graph property would silently shadow an ActiveRecord column.
  #
  # A module included into an ActiveRecord class wins over the generated
  # attribute-methods module, with no warning of any kind, so a graph-only
  # `property :role` on a table that has a `role` column would replace the
  # column reader. Checked lazily, on first use, because a class body runs
  # before `db:create` and must not touch the connection.
  class PropertyCollision < StandardError; end

  # Raised when a value cannot be coerced into a usable RDF term.
  class InvalidTerm < TypeError; end

  # Raised when a subject IRI cannot be minted: no `iri:` lambda, no
  # {Configuration#base_uri}, or no `iri` column to persist it into.
  class IriError < StandardError; end

  # Gives an ActiveRecord model a subject IRI and a set of graph properties.
  #
  # The graph state of a record lives in a *companion object* — an
  # {ActiveTriples::Resource} subclass generated per model and reachable as
  # {#rdf_source} — not in the record itself. That is a deliberate departure
  # from the README's "the `property` DSL is ActiveTriples' `RDFSource`", and
  # it is forced: `include ActiveTriples::RDFSource` into an `ApplicationRecord`
  # succeeds silently and then destroys the model. Measured, not reasoned —
  # `docs/spec-corrections.md` §9 records the four failures.
  #
  # Composition keeps everything the README actually wanted from the library:
  # term coercion, multi-valued {ActiveTriples::Relation} reads, `dump
  # :ntriples`. It gives up nothing except the ability to say `include`.
  #
  # @example
  #   class Person < ApplicationRecord
  #     include PgRipple::Node
  #
  #     graph type: RDF::Vocab::FOAF.Person, iri: ->(p) { "people/#{p.id}" } do
  #       property :name,      predicate: RDF::Vocab::FOAF.name,     from: :name
  #       property :birthdate, predicate: RDF::Vocab::FOAF.birthday, from: :born_on
  #       property :role,      predicate: EX.role
  #     end
  #   end
  module Node
    extend ActiveSupport::Concern

    # One declared graph property.
    #
    # @!attribute [r] name
    #   @return [Symbol] the accessor name
    # @!attribute [r] predicate
    #   @return [RDF::URI]
    # @!attribute [r] from
    #   @return [Symbol, nil] the ActiveRecord column this property mirrors
    # @!attribute [r] cast
    #   @return [Class, #call, nil] how a Ruby value becomes an RDF term
    class Property
      attr_reader :name, :predicate, :from, :cast

      # @param name [#to_sym]
      # @param predicate [RDF::URI, PgRipple::Path, #to_term, String]
      # @param from [#to_sym, nil] an ActiveRecord column to mirror
      # @param cast [Class, #call, nil] `RDF::URI`, or any callable taking the
      #   Ruby value and returning an {RDF::Term}
      def initialize(name, predicate:, from: nil, cast: nil)
        @name = name.to_sym
        @predicate = self.class.coerce_predicate(predicate)
        @from = from&.to_sym
        @cast = cast
        freeze
      end

      # Whether the value lives in an ActiveRecord column rather than only in
      # the graph.
      #
      # @return [Boolean]
      def mirrored?
        !@from.nil?
      end

      # Whether the ActiveRecord attribute method *is already* this property's
      # reader, so generating one would shadow the column for no gain.
      #
      # @return [Boolean]
      def shadows_column_accessor?
        @from == @name
      end

      # A Ruby value as the RDF term this property stores.
      #
      # @param value [Object]
      # @return [RDF::Term, Object, nil] an {RDF::Term} when a `cast:` applies;
      #   otherwise the value untouched, for {ActiveTriples} to coerce.
      # @raise [PgRipple::InvalidTerm] when the cast produces an invalid term —
      #   `RDF::URI("alice@example.com")` builds happily and is not a usable
      #   IRI, and a relative IRI written as an object is a silent data bug.
      def coerce(value)
        return nil if value.nil?
        return value if @cast.nil? || value.is_a?(RDF::Term)

        term = @cast.is_a?(Class) ? @cast.new(value.to_s) : @cast.call(value)

        if term.is_a?(RDF::URI) && !term.valid?
          raise InvalidTerm,
            "#{name} cast #{value.inspect} to #{term.to_s.inspect}, which is not a valid IRI"
        end

        term
      end

      # @param predicate [Object]
      # @return [RDF::URI]
      def self.coerce_predicate(predicate)
        raise ArgumentError, "property requires a predicate:" if predicate.nil?

        term = predicate.respond_to?(:to_term) ? predicate.to_term : predicate
        uri = RDF::URI.intern(term)

        raise ArgumentError, "predicate #{predicate.inspect} is not a valid IRI" unless uri.valid?

        uri
      end
    end

    # What one `graph … do … end` block declared.
    #
    # The block is evaluated against this object, which is why `property` reads
    # as a bare macro inside it and is not a method on the model class.
    class Schema
      # @return [Class] the ActiveRecord model
      attr_reader :model

      # @return [Array<RDF::URI>] the `rdf:type`s every subject carries
      attr_reader :types

      # @return [#call, nil] returns the subject's path relative to
      #   {Configuration#base_uri}
      attr_reader :iri_template

      # @return [Hash{Symbol => PgRipple::Node::Property}]
      attr_reader :properties

      # @return [Class] the {ActiveTriples} persistence strategy graph writes
      #   go through
      attr_reader :persistence_strategy

      # @return [Symbol, nil] `:nullify_references`, or nil
      attr_reader :dependent

      # @param model [Class]
      # @param type [RDF::URI, Array<RDF::URI>, nil]
      # @param iri [#call, nil]
      # @param persistence_strategy [Class]
      # @param dependent [Symbol, nil]
      def initialize(model, **options)
        @model = model
        @types = [].freeze
        @iri_template = nil
        @persistence_strategy = PgRipple::Persistence::DiffStrategy
        @dependent = nil
        @properties = {}

        configure(**options)
      end

      # Applies the options of one `graph …` call.
      #
      # Additive, because the README declares a mapping across more than one
      # call — `graph dependent: :nullify_references` on its own is an
      # amendment to the block that declared the properties, not a second
      # mapping that replaces it. An option not passed is left alone.
      #
      # @return [self]
      def configure(type: nil, iri: nil, persistence_strategy: nil, dependent: nil)
        @types = (@types + Array.wrap(type).map { |t| RDF::URI.intern(t) }).uniq.freeze
        @iri_template = iri unless iri.nil?
        @persistence_strategy = persistence_strategy unless persistence_strategy.nil?
        @dependent = validate_dependent(dependent) unless dependent.nil?
        self
      end

      # A copy of this schema belonging to a subclass.
      #
      # @param model [Class]
      # @return [PgRipple::Node::Schema]
      def for(model)
        copy = Schema.new(
          model, type: types, iri: iri_template,
          persistence_strategy: persistence_strategy, dependent: dependent
        )
        properties.each_value { |prop| copy.properties[prop.name] = prop }
        copy
      end

      # Whether destroying a record also retracts the edges pointing at it.
      #
      # @return [Boolean]
      def nullify_references?
        @dependent == :nullify_references
      end

      # Whether graph writes are the diff rather than a whole-object rewrite.
      #
      # @return [Boolean]
      def diffing?
        @persistence_strategy <= PgRipple::Persistence::DiffStrategy
      end

      # Declares a graph property. Only meaningful inside a `graph` block.
      #
      # @param name [Symbol]
      # @param predicate [RDF::URI, PgRipple::Path]
      # @param from [Symbol, nil] an ActiveRecord column to mirror into the
      #   graph. Omit it and the value lives only in the graph.
      # @param cast [Class, #call, nil]
      # @return [PgRipple::Node::Property]
      def property(name, predicate:, from: nil, cast: nil)
        prop = Property.new(name, predicate: predicate, from: from, cast: cast)
        @properties[prop.name] = prop
      end

      # @param name [#to_sym]
      # @return [PgRipple::Node::Property, nil]
      def [](name)
        @properties[name.to_sym]
      end

      # @param name [#to_sym]
      # @return [PgRipple::Node::Property]
      # @raise [PgRipple::UnknownProperty]
      def fetch(name)
        self[name] || raise(unknown(name))
      end

      # @param term [RDF::URI, #to_term]
      # @return [PgRipple::Node::Property, nil]
      def property_for_predicate(term)
        uri = term.respond_to?(:to_term) ? term.to_term : term
        @properties.each_value.find { |p| p.predicate == uri }
      end

      # @param term [RDF::URI, #to_term]
      # @return [PgRipple::Node::Property]
      # @raise [PgRipple::UnknownProperty]
      def fetch_predicate(term)
        property_for_predicate(term) || raise(unknown(term))
      end

      # @return [Array<Symbol>]
      def names
        @properties.keys
      end

      # The generated {ActiveTriples::Resource} subclass holding graph state.
      #
      # @return [Class]
      def source_class
        @source_class ||= build_source_class
      end

      private

      # `dependent:` is checked eagerly, in the class body, because a typo here
      # fails *open*: `dependent: :nullify_refrences` would silently leave the
      # inbound edges behind and nothing would ever say so.
      def validate_dependent(value)
        return nil if value.nil?
        return value.to_sym if value.to_sym == :nullify_references

        raise ArgumentError,
          "graph dependent: #{value.inspect} is not supported; the only value is :nullify_references"
      end

      def unknown(name)
        UnknownProperty.new(
          "unknown graph property #{name.inspect} for #{model.name}; " \
          "declared: #{names.map(&:inspect).join(", ")}",
          name.respond_to?(:to_sym) ? name.to_sym : name
        )
      end

      def build_source_class
        klass = Class.new(ActiveTriples::Resource)
        model.const_set(:GraphSource, klass) unless model.const_defined?(:GraphSource, false)
        klass.configure(type: types) unless types.empty?

        # Only for the opt-back-in. `ActiveTriples::RepositoryStrategy`
        # resolves its repository by *name*, out of ActiveTriples' global
        # registry; {DiffStrategy} is handed one directly. Declaring it
        # unconditionally would be worse than useless: `RDFSource#initialize`
        # reloads through whatever strategy is current, so a class naming a
        # repository would read the store during `new` — before the strategy
        # has even been swapped — and raise if the name was not registered yet.
        klass.configure(repository: PgRipple::REPOSITORY_NAME) unless diffing?

        @properties.each_value do |prop|
          # `cast: false` on ActiveTriples' side is not our `cast:`. Theirs is a
          # boolean meaning "wrap resource-valued objects in an RDFSource"; with
          # it on, an `RDF::URI` object reads back as an ActiveTriples::Resource
          # rather than the term that was written. We always want the term.
          klass.property(prop.name, predicate: prop.predicate, cast: false)
        rescue ArgumentError => e
          raise PropertyCollision,
            "graph property #{prop.name.inspect} on #{model.name} cannot be declared: #{e.message}"
        end

        klass
      end
    end

    class_methods do
      # Declares the model's graph mapping, or opens a graph query.
      #
      # With a block it is the class macro the README's "Models" section shows.
      # Without one it is the `Person.graph.where(…)` relation entry point,
      # which a later phase owns; this class defers to `graph_relation` when
      # something has defined it.
      #
      # @param type [RDF::URI, Array<RDF::URI>, nil] the `rdf:type`(s) subjects
      #   of this model carry
      # @param iri [#call] given the record, returns its path relative to
      #   {Configuration#base_uri}
      # @param persistence_strategy [Class] the {ActiveTriples} strategy graph
      #   writes go through. The default, {PgRipple::Persistence::DiffStrategy},
      #   emits only what changed; `ActiveTriples::RepositoryStrategy` opts back
      #   into the library's whole-object rewrite, at the cost the README's
      #   "How writes work" describes.
      # @param dependent [Symbol, nil] `:nullify_references` to also retract
      #   the edges pointing *at* a destroyed subject
      # @yield the property declarations, evaluated against a {Schema}
      # @return [PgRipple::Node::Schema]
      def graph(**options, &block)
        if block.nil? && options.empty?
          return graph_relation if respond_to?(:graph_relation)

          raise ArgumentError,
            "#{name}.graph requires a block declaring the graph mapping"
        end

        schema = own_graph_schema || Schema.new(self)
        schema.configure(**options)
        schema.instance_eval(&block) if block
        self.graph_schema = schema
        define_graph_accessors(schema)
        schema
      end

      # Raises unless every declared property can coexist with the table.
      #
      # Run once per class, lazily, the first time a graph accessor is used —
      # never from the class body, where the connection may not exist yet.
      #
      # @return [true]
      # @raise [PgRipple::PropertyCollision]
      def validate_graph_properties!
        return true if @graph_properties_validated

        columns = column_names.map(&:to_sym)

        graph_schema.properties.each_value do |prop|
          if prop.mirrored? && !columns.include?(prop.from)
            raise PropertyCollision,
              "graph property #{prop.name.inspect} on #{name} mirrors #{prop.from.inspect}, " \
              "which is not a column of #{table_name}"
          end

          if !prop.mirrored? && columns.include?(prop.name)
            raise PropertyCollision,
              "graph property #{prop.name.inspect} on #{name} would shadow the " \
              "#{prop.name.inspect} column; give it `from: :#{prop.name}` or rename it"
          end
        end

        @graph_properties_validated = true
      end

      private

      # The schema this class declared itself, as opposed to one inherited
      # through the `class_attribute`. A subclass amending its parent's mapping
      # gets a copy to amend; mutating the parent's would rewrite it for every
      # sibling.
      #
      # @return [PgRipple::Node::Schema, nil]
      def own_graph_schema
        return nil if graph_schema.nil?
        return graph_schema if graph_schema.model == self

        graph_schema.for(self)
      end

      # The module the generated readers and writers live in.
      #
      # A module rather than `define_method` on the class so a host application
      # can `super` into a generated accessor from the model body.
      #
      # @return [Module]
      def generated_graph_methods
        @generated_graph_methods ||= begin
          mod = const_set(:GeneratedGraphMethods, Module.new)
          include mod

          mod
        end
      end

      def define_graph_accessors(schema)
        mod = generated_graph_methods

        schema.properties.each_value do |prop|
          name = prop.name

          mod.define_method(:"#{name}_values") { ripple_read_values(name) }

          # When the property mirrors the column it is named after, the
          # ActiveRecord attribute method already *is* the reader. Generating
          # one would shadow the column with a delegation to itself: all risk,
          # no behaviour.
          next if prop.shadows_column_accessor?

          mod.define_method(name) { ripple_read(name) }
          mod.define_method(:"#{name}=") { |value| ripple_write(name, value) }
        end
      end
    end

    included do
      # `graph_has_many`, `graph_has_one` and the `Model.graph` entry point that
      # {.graph} defers to. A second concern rather than more of this one: an
      # association is a *query*, and nothing about it needs the property
      # schema.
      include PgRipple::Associations

      # @return [PgRipple::Node::Schema, nil]
      class_attribute :graph_schema, instance_writer: false, default: nil

      # `after_create` before `after_save`, which is the order ActiveRecord
      # runs them in and the order this needs: the subject IRI is a function of
      # `id`, so there is nothing to write triples about until the insert has
      # returned. Both are ordinary callbacks inside the record's own
      # transaction — no `after_commit`, because the whole point is that the
      # triples roll back with the row.
      after_create :assign_ripple_iri
      after_save :persist_ripple_graph
      after_destroy :destroy_ripple_graph
    end

    # The record's subject IRI.
    #
    # The stored column when there is one — that is the value every query joins
    # on and it must not drift — and otherwise the minted value. `nil` for an
    # unsaved record, whose IRI does not exist yet: the README's `iri:` lambda
    # is a function of `id`, which the insert assigns.
    #
    # @return [String, nil]
    def iri
      stored = ripple_stored_iri
      return stored if stored.present?
      return nil if new_record?

      mint_iri
    end

    # The record as an RDF term.
    #
    # An {RDF::URI} once the record is saved. Before that it is an {RDF::Node}:
    # graph values set in memory attach to a blank node, and {#assign_ripple_iri}
    # rewrites them onto the minted IRI when the row gets its id.
    #
    # @return [RDF::URI, RDF::Node]
    def rdf_subject
      rdf_source.rdf_subject
    end

    # The record's graph state, as an {ActiveTriples::RDFSource}.
    #
    # The seam every other part of the gem goes through: `dump :ntriples`,
    # `each_statement`, `get_values`. Loaded from the store on first use for a
    # persisted record; a fresh in-memory graph otherwise.
    #
    # @return [ActiveTriples::Resource]
    def rdf_source
      @rdf_source ||= build_rdf_source
    end

    # Discards the loaded graph along with the row.
    #
    # @return [self]
    def reload(...)
      @rdf_source = nil
      super
    end

    # The value of a graph property, by name.
    #
    # @param name [Symbol]
    # @return [Object, nil]
    # @raise [PgRipple::UnknownProperty]
    def ripple_read(name)
      prop = ripple_schema.fetch(name)

      if prop.mirrored?
        read_attribute(prop.from)
      else
        rdf_source.get_values(prop.name).first
      end
    end

    # Every value of a graph property, by name.
    #
    # Graph properties are sets; a scalar reader is a convenience that SHACL's
    # `sh:maxCount 1` is what actually justifies — see "Where the abstraction
    # leaks". A mirrored property answers from its column, which holds exactly
    # one value by construction.
    #
    # @param name [Symbol]
    # @return [Array]
    # @raise [PgRipple::UnknownProperty]
    def ripple_read_values(name)
      prop = ripple_schema.fetch(name)

      if prop.mirrored?
        Array.wrap(read_attribute(prop.from))
      else
        rdf_source.get_values(prop.name).to_a
      end
    end

    # Sets a graph property, by name.
    #
    # @param name [Symbol]
    # @param value [Object]
    # @return [Object] the value
    # @raise [PgRipple::UnknownProperty]
    def ripple_write(name, value)
      prop = ripple_schema.fetch(name)

      if prop.mirrored?
        write_attribute(prop.from, value)
      else
        coerced = value.is_a?(Array) ? value.map { |v| prop.coerce(v) } : prop.coerce(value)
        rdf_source.set_value(prop.name, coerced)
      end

      value
    end

    # The IRI this record's `iri:` lambda and {Configuration#base_uri} produce.
    #
    # Resolved with {RDF::URI#join}, which is RFC 3986 reference resolution and
    # therefore *drops* the last path segment of a base that has no trailing
    # slash: `"https://app.example.com/app"` joined with `"people/1"` is
    # `"https://app.example.com/people/1"`. A base URI is a prefix, not a
    # document, so a trailing slash is added when it is missing and a leading
    # one is stripped off the relative part.
    #
    # @return [String]
    # @raise [PgRipple::IriError]
    def mint_iri
      schema = ripple_schema
      template = schema.iri_template
      raise IriError, "#{self.class.name} has no iri: lambda" if template.nil?

      relative = template.call(self).to_s
      return relative if RDF::URI(relative).absolute?

      base = PgRipple.configuration.base_uri
      raise IriError, "PgRipple.configuration.base_uri is not set" if base.blank?

      base = base.to_s
      base += "/" unless base.end_with?("/")

      RDF::URI(base).join(relative.delete_prefix("/")).to_s
    end

    private

    # @return [PgRipple::Node::Schema]
    def ripple_schema
      schema = self.class.graph_schema
      raise IriError, "#{self.class.name} has no graph mapping" if schema.nil?

      self.class.validate_graph_properties!
      schema
    end

    # @return [String, nil]
    def ripple_stored_iri
      has_attribute?(:iri) ? self[:iri] : nil
    end

    def build_rdf_source
      schema = ripple_schema

      # Before `new`, not after: `ActiveTriples::RDFSource#initialize` reloads
      # through the current strategy, and for a class that names a repository
      # that read happens inside the constructor.
      unless schema.diffing?
        ActiveTriples::Repositories.add_repository(PgRipple::REPOSITORY_NAME, PgRipple.repository)
      end

      source = schema.source_class.new(*[iri].compact)
      install_ripple_strategy(source)
      source.reload if persisted? && source.uri?
      source
    end

    # Swaps in the model's persistence strategy, carrying the graph across.
    #
    # ActiveTriples instantiates its default strategy the first time anything
    # touches `#graph`, and `RDFSource#initialize` already has: a `configure
    # type:` writes the `rdf:type` statement during `new`. So the graph exists
    # before the strategy is replaced, and `set_persistence_strategy` gives the
    # replacement a fresh empty one. Handing the old graph over is what stops
    # the type triple from disappearing between construction and the first
    # save.
    def install_ripple_strategy(source)
      existing = source.persistence_strategy.graph
      source.set_persistence_strategy(ripple_schema.persistence_strategy)
      source.persistence_strategy.graph = existing
      source
    end

    # Mints the subject IRI once the insert has assigned an id, and moves any
    # in-memory graph state from the blank node onto it.
    def assign_ripple_iri
      return if self.class.graph_schema.nil?
      return if ripple_stored_iri.present?

      unless has_attribute?(:iri)
        raise IriError,
          "#{self.class.table_name} has no iri column; add one with " \
          "`add_column :#{self.class.table_name}, :iri, :string`"
      end

      value = mint_iri
      update_column(:iri, value)
      @rdf_source&.set_subject!(value)
    end

    # Writes the graph difference, in the record's own transaction.
    #
    # Skipped entirely when there is nothing that could have changed: an update
    # that touched no mirrored column and never built a graph for this record
    # cannot have moved a triple, and building one to discover that would cost
    # a read per save.
    def persist_ripple_graph
      return if self.class.graph_schema.nil?

      mirrored = ripple_changed_mirrored_properties
      return if @rdf_source.nil? && mirrored.empty? && !previously_new_record?

      project_ripple_columns(mirrored)
      rdf_source.persist!
    end

    # Retracts the subject's triples when the row goes.
    #
    # A `DELETE WHERE { <iri> ?p ?o }` rather than a diff: the subject is gone,
    # so there is nothing to preserve, and it is authoritative even when this
    # process never loaded the record's graph. `dependent: :nullify_references`
    # adds the inbound sweep, which is the one thing ActiveTriples does not do
    # and nothing else can do cheaply from this side.
    #
    # Goes to {PgRipple::Persistence} rather than through the strategy, so it
    # behaves the same under `ActiveTriples::RepositoryStrategy` — and so
    # destroying a record never has to load its graph first.
    def destroy_ripple_graph
      schema = self.class.graph_schema
      return if schema.nil?
      return if iri.blank?

      subject = RDF::URI(iri)

      PgRipple::Persistence.nullify_references(subject) if schema.nullify_references?
      PgRipple::Persistence.erase(subject)

      @rdf_source = nil
    end

    # The mirrored properties whose column this save actually changed.
    #
    # `saved_changes` rather than `changes`: by `after_save` the mutations have
    # moved, and on a create it holds every attribute the insert wrote, which
    # is exactly the set that needs projecting the first time.
    #
    # @return [Array<PgRipple::Node::Property>]
    def ripple_changed_mirrored_properties
      changed = saved_changes.keys

      self.class.graph_schema.properties.each_value.select do |prop|
        prop.mirrored? && changed.include?(prop.from.to_s)
      end
    end

    # Copies changed column values into the graph.
    #
    # This is the only thing {ActiveModel::Dirty} decides: *which* columns to
    # re-project. The delta that reaches the wire is still the graph difference
    # {PgRipple::Persistence::DiffStrategy} computes, so re-projecting a column
    # whose value did not really move writes nothing.
    def project_ripple_columns(properties)
      properties.each do |prop|
        value = read_attribute(prop.from)

        rdf_source.set_value(prop.name, value.nil? ? [] : prop.coerce(value))
      end
    end
  end
end

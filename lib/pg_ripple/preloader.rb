# frozen_string_literal: true

require "json"
require "rdf"

require "pg_ripple/prefixes"
require "pg_ripple/term"

module PgRipple
  # One `CONSTRUCT`, shaped by a JSON-LD frame, for a whole page of records.
  #
  # This is what `graph_includes` runs. Given the loaded records of a relation
  # and the names of some graph associations, it asks the store *once* for
  # every edge those associations reach, loads the far side in one SQL query
  # per target class, and hands each record its own slice — so
  # `person.reports` afterwards is a loaded relation and queries nothing.
  #
  # ### The shape of the query, and why it is not the README's
  #
  # `docs/probe-jsonld-framing.md` measured what pg_ripple 0.128.0 really does
  # with `sparql_construct_jsonld` and `jsonld_frame`. Six of its findings are
  # load-bearing here, and two more were measured while building this class
  # (`docs/spec-corrections.md` §18):
  #
  # 1. **`PREFIX` lines are emitted.** A registered prefix is invisible to the
  #    SPARQL parser, in a CONSTRUCT template as much as anywhere else.
  # 2. **The frame matches roots on `@type`, so the template asserts one.** The
  #    type it asserts is {ROOT_TYPE} — this gem's own, not the model's
  #    declared `graph type:`. Nothing is written, so an invented IRI costs
  #    nothing, and it means `graph_includes` works on a model that declares no
  #    type at all and cannot be confused by a subject that happens to carry
  #    the model's type for some other reason.
  # 3. **Every association is projected onto its own {SLOT_PREFIX} predicate.**
  #    This is what makes a *path* association preloadable: a frame nests
  #    properties, and `+ex.manages` is not a property. The path stays in the
  #    `WHERE`, where SPARQL evaluates it, and the CONSTRUCT template names a
  #    flat synthetic predicate the frame can nest. Measured: a transitive
  #    `+` path projected this way returns the whole reachable set (bob *and*
  #    carol), which is what `alice.reports` means.
  # 4. **Sibling `OPTIONAL`s are a Cartesian product**, so the branches are one
  #    `OPTIONAL { … UNION … }` instead. Two sibling `OPTIONAL`s over 3 reports
  #    and 1 employer emit the employer 3×; the `UNION` emits it once. Solutions
  #    go from the product of the branches to their sum.
  # 5. **`@embed => '@always'`.** Under the default `@once` a node shared by two
  #    roots is embedded under one of them and left a bare reference under the
  #    other, decided by hash order.
  # 6. **The sub-frames are empty `{}` on purpose.** An empty sub-frame does not
  #    embed the child's properties — and this is the one consumer that wants
  #    exactly that: the child is hydrated from its *table* by `iri`, so the
  #    only thing needed from the graph is the reference. Nothing here would be
  #    faster if the child's triples came back too.
  # 7. **A one-root result is not wrapped in `@graph`.** With two or more roots
  #    the document is `{"@graph": [...]}`; with exactly one it is the bare node
  #    object. {.nodes} handles both, and it is not academic: it is a page of
  #    one, i.e. every `find`-shaped preload.
  # 8. **IRIs come back bare.** No angle brackets anywhere in JSON-LD output, at
  #    any depth — the settled `btrim(…, '<>')` belongs to the lateral
  #    `sparql()` path and would corrupt these. A value that is a literal
  #    rather than a reference has no `@id` at all and is dropped here rather
  #    than becoming a `nil` record.
  #
  # Values are always arrays, at every level, one value or many
  # (`probe-jsonld-framing.md` §c), so there is no one-vs-many special case to
  # write — but cardinality is *not* trustworthy, so children are de-duplicated
  # by `@id`.
  #
  # @api private
  class Preloader
    # The `rdf:type` the frame matches roots on. Asserted by the CONSTRUCT
    # template, never stored.
    ROOT_TYPE = RDF::URI("urn:x-pg-ripple:frame-root")

    # Each association's synthetic predicate is this plus its position.
    #
    # Position, not name: an association name is a Ruby symbol from a class
    # body and an IRI is not a place to find out that it contained a space. The
    # position is the index into the same array the template, the frame and the
    # reader all walk, so there is one thing to get wrong and it is checked by
    # construction.
    SLOT_PREFIX = "urn:x-pg-ripple:include:"

    # The subject variable, matching {PgRipple::Query::SUBJECT}'s role.
    SUBJECT = "s"

    # @param records [Array<ActiveRecord::Base>] the loaded page
    # @param names [Array<Symbol>] graph association names
    # @param model [Class] the relation's model
    # @return [Array<ActiveRecord::Base>] the same records
    def self.call(records, names, model:)
      new(records, names, model: model).call
    end

    def initialize(records, names, model:)
      @records = Array(records)
      @model = model
      @definitions = Array(names).map { |name| definition_for(name) }
    end

    # @return [Array<ActiveRecord::Base>]
    def call
      return @records if @definitions.empty?

      # A record with no subject IRI has no edges to preload and nothing to
      # join on. It is left untouched rather than marked loaded-and-empty, so
      # reading its association still raises {PgRipple::IriError} — the honest
      # error — instead of quietly answering "none".
      subjects = @records.select { |record| record.iri.present? }
      return @records if subjects.empty?

      # Grouped by graph: `graph_name:` is per association, and one CONSTRUCT
      # cannot be scoped to two graphs at once. One round trip per *graph*,
      # which for the overwhelmingly common case of one graph is one round trip.
      @definitions.group_by(&:graph_name).each do |graph_name, definitions|
        hydrate(graph_name, definitions, subjects)
      end

      @records
    end

    # The SPARQL a group of associations compiles to.
    #
    # Public so a spec can assert the text and a developer can read it.
    #
    # @param definitions [Array<PgRipple::Associations::Definition>]
    # @param subjects [Array<RDF::URI>]
    # @param graph_name [RDF::URI, nil]
    # @return [String]
    def self.construct(definitions, subjects, graph_name: nil)
      template = ["?#{SUBJECT} a #{PgRipple::Term.sparql(ROOT_TYPE)} ."]
      branches = []

      definitions.each_with_index do |definition, index|
        template << "?#{SUBJECT} #{PgRipple::Term.sparql(slot(index))} ?#{variable(index)} ."
        branches << "{ ?#{SUBJECT} #{definition.path} ?#{variable(index)} }"
      end

      body = branches.join("\n    UNION\n    ")
      body = "GRAPH #{PgRipple::Term.sparql(graph_name)} { #{body} }" unless graph_name.nil?
      values = subjects.map { |subject| PgRipple::Term.sparql(subject) }.join(" ")

      PgRipple::Prefixes.declarations(definitions.flat_map { |d| d.path.prefixes }.uniq.sort) +
        "CONSTRUCT {\n  #{template.join("\n  ")}\n}\n" \
        "WHERE {\n" \
        "  VALUES ?#{SUBJECT} { #{values} }\n" \
        "  OPTIONAL {\n    #{body}\n  }\n}\n"
    end

    # The frame that group is shaped by.
    #
    # @param definitions [Array<PgRipple::Associations::Definition>]
    # @return [Hash]
    def self.frame(definitions)
      frame = {"@type" => ROOT_TYPE.to_s}
      definitions.each_index { |index| frame[slot(index).to_s] = {} }
      frame
    end

    # @param index [Integer]
    # @return [RDF::URI]
    def self.slot(index)
      RDF::URI("#{SLOT_PREFIX}#{Integer(index)}")
    end

    # @param index [Integer]
    # @return [String]
    def self.variable(index)
      "o#{Integer(index)}"
    end

    # The framed document's node objects, keyed by IRI.
    #
    # Handles both shapes the extension returns: `{"@graph": [...]}` for two or
    # more roots, and a bare node object for exactly one.
    #
    # @param document [Hash, nil]
    # @return [Hash{String => Hash}]
    def self.nodes(document)
      return {} unless document.is_a?(Hash)

      pool =
        if document.key?("@graph")
          Array(document["@graph"])
        elsif document.key?("@id")
          [document]
        else
          []
        end

      pool.each_with_object({}) do |node, index|
        index[node["@id"]] = node if node.is_a?(Hash) && node["@id"].is_a?(String)
      end
    end

    private

    def hydrate(graph_name, definitions, subjects)
      document = PgRipple.repository(graph_name: graph_name).construct_framed(
        self.class.construct(definitions, subjects.map { |r| RDF::URI(r.iri) }.uniq, graph_name: graph_name),
        self.class.frame(definitions)
      )

      nodes = self.class.nodes(document)
      references = subjects.to_h { |record| [record.iri, references_for(nodes[record.iri], definitions)] }
      targets = load_targets(definitions, references)

      subjects.each do |record|
        definitions.each_with_index do |definition, index|
          rows = targets.fetch(definition.target, {})
          record.pg_ripple_graph_association_loaded(
            definition.name,
            references.fetch(record.iri)[index].filter_map { |iri| rows[iri] }
          )
        end
      end
    end

    # One record's child IRIs, per association, de-duplicated.
    #
    # An absent key is an `OPTIONAL` that did not match, which is an empty
    # collection — there is no `null` and no `[]` in the payload to tell it
    # apart from "never asked", so this drives off `definitions` and never off
    # the keys that came back (`probe-jsonld-framing.md` §d).
    def references_for(node, definitions)
      definitions.each_index.map do |index|
        values = node.nil? ? [] : Array(node[self.class.slot(index).to_s])

        values.filter_map { |value| value["@id"] if value.is_a?(Hash) && value["@id"].is_a?(String) }.uniq
      end
    end

    # One SQL query per target class, not one per association: two associations
    # onto the same model are one `WHERE iri IN (…)`.
    def load_targets(definitions, references)
      wanted = Hash.new { |hash, klass| hash[klass] = [] }

      definitions.each_with_index do |definition, index|
        references.each_value { |per_definition| wanted[definition.target].concat(per_definition[index]) }
      end

      wanted.to_h do |klass, iris|
        iris = iris.uniq
        next [klass, {}] if iris.empty?

        unless klass.column_names.include?("iri")
          raise PgRipple::IriError,
            "#{klass.name} has no iri column, so it cannot be preloaded; " \
            "add one with `add_column :#{klass.table_name}, :iri, :string`"
        end

        [klass, klass.where(iri: iris).index_by(&:iri)]
      end
    end

    def definition_for(name)
      @model.graph_associations.fetch(name.to_sym) do
        raise ArgumentError,
          "#{@model.name} has no graph association #{name.inspect}; " \
          "declared: #{@model.graph_associations.keys.map(&:inspect).join(", ")}"
      end
    end
  end
end

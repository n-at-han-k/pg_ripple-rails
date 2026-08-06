# frozen_string_literal: true

require "spec_helper"

# The text `graph_includes` sends and the document it reads back, without a
# database. Every claim here was measured first against a live pg_ripple
# 0.128.0 and is recorded in `docs/probe-jsonld-framing.md` or in
# `docs/spec-corrections.md` §18; this file is what stops the query drifting
# away from what was measured.
RSpec.describe PgRipple::Preloader do
  let(:ex) { PgRipple::Path.vocabulary("https://app.example.com/ns#", prefix: "ex") }

  # No `owner:` reflection is needed to render a query — only the path — and
  # `#target` is resolved lazily, so these need neither a table nor a model.
  def definition(name, path, class_name: "Person", arity: :many, graph_name: nil)
    PgRipple::Associations::Definition.new(
      name, owner: nil, path: path, class_name: class_name, arity: arity, graph_name: graph_name
    )
  end

  let(:subjects) { [RDF::URI("https://app.example.com/people/1"), RDF::URI("https://app.example.com/people/2")] }

  describe ".construct" do
    it "projects each association onto its own synthetic predicate" do
      sparql = described_class.construct(
        [definition(:reports, +ex.manages), definition(:employer, ex.worksAt)], subjects
      )

      expect(sparql).to eq(<<~SPARQL)
        PREFIX ex: <https://app.example.com/ns#>
        CONSTRUCT {
          ?s a <urn:x-pg-ripple:frame-root> .
          ?s <urn:x-pg-ripple:include:0> ?o0 .
          ?s <urn:x-pg-ripple:include:1> ?o1 .
        }
        WHERE {
          VALUES ?s { <https://app.example.com/people/1> <https://app.example.com/people/2> }
          OPTIONAL {
            { ?s ex:manages+ ?o0 }
            UNION
            { ?s ex:worksAt ?o1 }
          }
        }
      SPARQL
    end

    # The whole reason a path association is preloadable at all. A frame nests
    # *properties*; `ex:manages+` is not a property and cannot appear in one.
    # Projecting the traversal onto a flat synthetic predicate leaves the path
    # in the WHERE, where SPARQL evaluates it, and gives the frame something it
    # can nest. `docs/spec-corrections.md` §18.
    it "keeps the property path in the WHERE and out of the frame" do
      definitions = [definition(:colleagues, ~ex.worksAt / ex.worksAt)]
      sparql = described_class.construct(definitions, subjects)

      expect(sparql).to include("{ ?s ^ex:worksAt/ex:worksAt ?o0 }")
      expect(described_class.frame(definitions)).to eq(
        "@type" => "urn:x-pg-ripple:frame-root", "urn:x-pg-ripple:include:0" => {}
      )
    end

    # Two sibling OPTIONALs are a Cartesian product: 3 reports × 1 employer
    # emits the employer three times (`probe-jsonld-framing.md` §b.2). One
    # OPTIONAL over a UNION makes the solutions the *sum* of the branches.
    it "unions the branches rather than nesting sibling OPTIONALs" do
      sparql = described_class.construct(
        [definition(:reports, +ex.manages), definition(:employer, ex.worksAt)], subjects
      )

      expect(sparql.scan("OPTIONAL").length).to eq(1)
      expect(sparql).to include("UNION")
    end

    it "emits no UNION for a single association" do
      sparql = described_class.construct([definition(:reports, +ex.manages)], subjects)

      expect(sparql).not_to include("UNION")
      expect(sparql).to include("OPTIONAL {\n    { ?s ex:manages+ ?o0 }\n  }")
    end

    it "wraps the traversal in GRAPH, leaving VALUES outside it" do
      sparql = described_class.construct(
        [definition(:reports, +ex.manages)], subjects, graph_name: RDF::URI("https://app.example.com/hr")
      )

      expect(sparql).to include("VALUES ?s {")
      expect(sparql).to include("GRAPH <https://app.example.com/hr> { { ?s ex:manages+ ?o0 } }")
    end

    # A registered prefix is invisible to the SPARQL parser — in a CONSTRUCT
    # template as much as anywhere else (`probe-jsonld-framing.md` §b.1), which
    # is exactly why the README's published query does not parse.
    it "carries its own PREFIX lines" do
      expect(described_class.construct([definition(:reports, +ex.manages)], subjects))
        .to start_with("PREFIX ex: <https://app.example.com/ns#>\n")
    end

    # The subjects come from an `iri` column, and a column is not a place this
    # gem trusts. They go through {PgRipple::Term.sparql} like every other term
    # in the gem, so an IRI that could break out of the `VALUES` block is
    # refused rather than written.
    it "serializes subjects as terms rather than pasting them in" do
      expect { described_class.construct([definition(:reports, +ex.manages)], [RDF::URI('https://example.com/a"b>')]) }
        .to raise_error(ArgumentError, /excluded from SPARQL's IRIREF production/)
    end
  end

  describe ".frame" do
    # The sub-frames are empty on purpose. An empty `{}` does not embed the
    # child's properties (`probe-jsonld-framing.md` §b.4) — and this is the one
    # consumer that wants precisely that: the child comes back as a reference,
    # and the record behind it is loaded from its own table by `iri`.
    it "is a root type and one empty slot per association" do
      frame = described_class.frame([definition(:reports, +ex.manages), definition(:employer, ex.worksAt)])

      expect(frame).to eq(
        "@type" => "urn:x-pg-ripple:frame-root",
        "urn:x-pg-ripple:include:0" => {},
        "urn:x-pg-ripple:include:1" => {}
      )
    end

    # A compact IRI in a frame is never expanded, not even against the frame's
    # own `@context`: it becomes `<ex:manages>` in the generated query and
    # matches nothing, silently (`probe-jsonld-framing.md` §f). And a prefix
    # `@context` compacts `@id` on the way out, which would stop the document
    # joining on the `iri` column at all (§e).
    it "carries no @context and no compact IRI" do
      frame = described_class.frame([definition(:reports, +ex.manages)])

      expect(frame).not_to have_key("@context")
      expect(frame.keys).to all(satisfy { |key| key.start_with?("@") || key.include?("://") || key.start_with?("urn:") })
    end
  end

  describe ".nodes" do
    # Measured while building this class and *not* in the phase-4 probe, which
    # never framed a one-root page: with two or more roots the document is
    # `{"@graph": [...]}`, and with exactly one it is the bare node object.
    # A page of one is every `find`-shaped preload, so getting this wrong would
    # silently preload nothing for the commonest page there is.
    it "reads a multi-root document" do
      document = {"@graph" => [{"@id" => "https://example.com/a"}, {"@id" => "https://example.com/b"}]}

      expect(described_class.nodes(document).keys).to eq(["https://example.com/a", "https://example.com/b"])
    end

    it "reads a one-root document, which is not wrapped in @graph" do
      document = {"@id" => "https://example.com/a", "urn:x-pg-ripple:include:0" => [{"@id" => "https://example.com/b"}]}

      expect(described_class.nodes(document).keys).to eq(["https://example.com/a"])
    end

    it "reads an empty document, and a nil one" do
      expect(described_class.nodes({"@graph" => []})).to eq({})
      expect(described_class.nodes(nil)).to eq({})
    end
  end

  describe ".call" do
    it "does nothing without associations" do
      records = [Object.new]

      expect(described_class.call(records, [], model: Class.new)).to equal(records)
    end

    it "names the associations that do exist when asked for one that does not" do
      model = Class.new do
        def self.name = "Widget"

        def self.graph_associations = {reports: :definition}
      end

      expect { described_class.call([], [:sprockets], model: model) }
        .to raise_error(ArgumentError, /Widget has no graph association :sprockets.*declared: :reports/m)
    end
  end
end

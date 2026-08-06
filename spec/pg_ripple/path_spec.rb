# frozen_string_literal: true

require "pg_ripple/path"

RSpec.describe PgRipple::Path do
  # The prefix registry is process-global on purpose (a path must render in a
  # class body, before any connection exists), so each example gets it clean.
  around do |example|
    registered = PgRipple::Prefixes.registered
    PgRipple::Prefixes.clear!
    example.run
  ensure
    PgRipple::Prefixes.clear!
    registered.each { |prefix, expansion| PgRipple::Prefixes.register(prefix, expansion) }
  end

  let(:foaf) { described_class.vocabulary("http://xmlns.com/foaf/0.1/", prefix: "foaf") }
  let(:ex) { described_class.vocabulary("https://example.com/ns#", prefix: "ex") }
  let(:rdf) { described_class.vocabulary(RDF) }

  # The case the whole design turns on. Ruby binds unary `~` tighter than `/`,
  # SPARQL binds `^` tighter than `/`, and the two must agree — otherwise
  # `colleagues` silently returns everyone who works anywhere.
  describe "the precedence of unary ~ against /" do
    it "renders ^ex:worksAt/ex:worksAt, not ^(ex:worksAt/ex:worksAt)" do
      expect((~ex.worksAt / ex.worksAt).to_s).to eq("^ex:worksAt/ex:worksAt")
    end

    it "only inverts the left operand" do
      path = ~ex.worksAt / ex.worksAt

      expect(path.to_s).not_to eq("^(ex:worksAt/ex:worksAt)")
    end

    it "parenthesises when the inverse really is applied to a sequence" do
      expect((ex.worksAt / ex.worksAt).inverse.to_s).to eq("^(ex:worksAt/ex:worksAt)")
    end
  end

  describe "the README operator table" do
    it "renders a single predicate" do
      expect(foaf.knows.to_s).to eq("foaf:knows")
    end

    it "renders a sequence with /" do
      expect((foaf.knows / ex.worksAt).to_s).to eq("foaf:knows/ex:worksAt")
    end

    it "renders an alternative with |" do
      expect((foaf.knows | ex.colleague).to_s).to eq("foaf:knows|ex:colleague")
    end

    it "renders one-or-more with unary +" do
      expect((+foaf.knows).to_s).to eq("foaf:knows+")
    end

    it "renders zero-or-more with #any" do
      expect(foaf.knows.any.to_s).to eq("foaf:knows*")
    end

    it "renders optional with #opt" do
      expect(foaf.knows.opt.to_s).to eq("foaf:knows?")
    end

    it "renders an inverse with unary ~" do
      expect((~ex.manages).to_s).to eq("^ex:manages")
    end

    it "renders a negated property set with unary !" do
      expect((!rdf.type).to_s).to eq("!(rdf:type)")
    end
  end

  describe "the README value examples" do
    let(:path) { ~ex.worksAt / ex.worksAt }

    it "renders #to_s" do
      expect(path.to_s).to eq("^ex:worksAt/ex:worksAt")
    end

    it "answers #inverse without mutating the receiver" do
      expect(path.inverse.to_s).to eq("^(^ex:worksAt/ex:worksAt)")
      expect(path.to_s).to eq("^ex:worksAt/ex:worksAt")
    end
  end

  describe "precedence between the binary operators" do
    it "leaves a sequence inside an alternative unparenthesised" do
      expect((foaf.knows / ex.worksAt | ex.colleague / ex.worksAt).to_s)
        .to eq("foaf:knows/ex:worksAt|ex:colleague/ex:worksAt")
    end

    it "parenthesises an alternative inside a sequence" do
      expect(((foaf.knows | ex.colleague) / ex.worksAt).to_s)
        .to eq("(foaf:knows|ex:colleague)/ex:worksAt")
    end

    it "parenthesises an alternative on the right of a sequence" do
      expect((ex.worksAt / (foaf.knows | ex.colleague)).to_s)
        .to eq("ex:worksAt/(foaf:knows|ex:colleague)")
    end

    it "keeps a three-way sequence flat" do
      expect((foaf.knows / ex.worksAt / ex.manages).to_s)
        .to eq("foaf:knows/ex:worksAt/ex:manages")
    end

    it "keeps a three-way alternative flat" do
      expect((foaf.knows | ex.worksAt | ex.manages).to_s)
        .to eq("foaf:knows|ex:worksAt|ex:manages")
    end
  end

  describe "precedence of the unary operators" do
    it "applies unary + to the left operand only" do
      expect((+foaf.knows / ex.worksAt).to_s).to eq("foaf:knows+/ex:worksAt")
    end

    it "parenthesises a sequence under one-or-more" do
      expect((foaf.knows / ex.worksAt).one_or_more.to_s).to eq("(foaf:knows/ex:worksAt)+")
    end

    it "parenthesises an alternative under zero-or-more" do
      expect((foaf.knows | ex.worksAt).any.to_s).to eq("(foaf:knows|ex:worksAt)*")
    end

    it "parenthesises a sequence under optional" do
      expect((foaf.knows / ex.worksAt).opt.to_s).to eq("(foaf:knows/ex:worksAt)?")
    end

    it "parenthesises an alternative under inverse" do
      expect((foaf.knows | ex.worksAt).inverse.to_s).to eq("^(foaf:knows|ex:worksAt)")
    end

    # SPARQL's PathEltOrInverse is `'^'? PathPrimary PathMod?`, so `^a+` already
    # means `^(a+)` and no parentheses are needed.
    it "leaves a modified atom unparenthesised under inverse" do
      expect((~+ex.manages).to_s).to eq("^ex:manages+")
    end

    it "stacks modifiers by parenthesising" do
      expect((+foaf.knows).opt.to_s).to eq("(foaf:knows+)?")
    end

    # `PathEltOrInverse` admits at most one '^', so `^^a` is a syntax error and
    # not a double inverse. An inverse already sits at MOD, so the precedence
    # rule alone let the carets stack: `~~ex.manages` rendered `^^ex:manages`,
    # which the `sparql` gem refuses to parse. Reachable from the README's own
    # `path.inverse`, which it advertises on an arbitrary path.
    it "parenthesises an inverse under inverse" do
      expect((~~ex.manages).to_s).to eq("^(^ex:manages)")
      expect(ex.manages.inverse.inverse.to_s).to eq("^(^ex:manages)")
    end

    it "parenthesises an inverted sequence under inverse" do
      expect((~(~ex.worksAt / ex.worksAt)).to_s).to eq("^(^ex:worksAt/ex:worksAt)")
    end
  end

  describe "negated property sets" do
    it "accepts an alternative of predicates" do
      expect((!(rdf.type | ex.worksAt)).to_s).to eq("!(rdf:type|ex:worksAt)")
    end

    # `!~ex.manages` is not writable: Ruby lexes `!~` as the does-not-match
    # operator before it ever sees two unary operators. Parenthesise, or use
    # `#negated`.
    it "accepts an inverse predicate" do
      expect((!(~ex.manages)).to_s).to eq("!(^ex:manages)")
      expect((~ex.manages).negated.to_s).to eq("!(^ex:manages)")
    end

    it "refuses a sequence, which is not a property set" do
      expect { !(rdf.type / ex.worksAt) }
        .to raise_error(ArgumentError, /negated property set/)
    end

    it "refuses a modified path" do
      expect { !+ex.manages }.to raise_error(ArgumentError, /negated property set/)
    end
  end

  describe "#to_term" do
    it "returns the RDF::URI of a single predicate" do
      term = foaf.knows.to_term

      expect(term).to be_a(RDF::URI)
      expect(term).to eq(RDF::URI("http://xmlns.com/foaf/0.1/knows"))
    end

    it "raises rather than returning a URI built from the rendered path" do
      expect { (+foaf.knows).to_term }
        .to raise_error(PgRipple::NotAPredicate, /not a single predicate/)
    end

    it "raises for a sequence" do
      expect { (foaf.knows / ex.worksAt).to_term }.to raise_error(PgRipple::NotAPredicate)
    end

    it "raises for an inverse, which is a direction and not a predicate" do
      expect { (~ex.manages).to_term }.to raise_error(PgRipple::NotAPredicate)
    end
  end

  describe "#single_predicate?" do
    it "is true for a leaf" do
      expect(foaf.knows).to be_single_predicate
    end

    it "is false for anything else" do
      expect(foaf.knows.opt).not_to be_single_predicate
    end
  end

  describe "leaf serialisation" do
    it "writes an unprefixed IRI in angle brackets, not bare" do
      path = described_class.term(RDF::URI("https://unregistered.example/p"))

      expect(path.to_s).to eq("<https://unregistered.example/p>")
    end

    # A bare `<…>` join would let a `>` in an IRI close the term early. Going
    # through RDF::URI#to_base stops that, but only by emitting an N-Triples
    # `>` escape, and SPARQL's IRIREF production has no UCHAR — the sparql
    # gem refuses to parse it. Percent-encoding would change the IRI, which RDF
    # compares by string, so there is nothing honest left to emit.
    it "raises on a character SPARQL cannot write in an IRI" do
      path = described_class.term(RDF::URI("https://unregistered.example/a>b"))

      expect { path.to_s }.to raise_error(ArgumentError, /IRIREF/)
    end

    it "refuses a String leaf, which is ambiguous between a pname and an IRI" do
      expect { described_class.term("foaf:knows") }.to raise_error(ArgumentError, /RDF::Term/)
    end

    it "refuses a String on the right of an operator" do
      expect { foaf.knows / "ex:worksAt" }.to raise_error(TypeError, /RDF::Term/)
    end

    it "accepts a bare RDF::URI on the right of an operator" do
      ex # register the prefix

      expect((foaf.knows / RDF::URI("https://example.com/ns#worksAt")).to_s)
        .to eq("foaf:knows/ex:worksAt")
    end
  end

  describe "prefixes" do
    it "reports the prefixes it used" do
      expect((~ex.worksAt / foaf.knows).prefixes).to eq(["ex", "foaf"])
    end

    it "omits a namespace it could not abbreviate" do
      path = foaf.knows / RDF::URI("https://unregistered.example/p")

      expect(path.prefixes).to eq(["foaf"])
    end

    it "emits the PREFIX declarations a query would need" do
      expect((~ex.worksAt / foaf.knows).prefix_declarations).to eq(<<~SPARQL)
        PREFIX ex: <https://example.com/ns#>
        PREFIX foaf: <http://xmlns.com/foaf/0.1/>
      SPARQL
    end

    it "falls back to RDF::Vocabulary for a vocabulary nobody registered" do
      expect(described_class.term(RDF.type).to_s).to eq("rdf:type")
    end

    it "prefers a locally registered prefix over the RDF::Vocabulary one" do
      PgRipple::Prefixes.register("r", RDF.to_uri.to_s)

      expect(described_class.term(RDF.type).to_s).to eq("r:type")
    end

    it "prefers the longest matching expansion" do
      PgRipple::Prefixes.register("hr", "https://example.com/ns#w")

      expect(ex.worksAt.to_s).to eq("hr:orksAt")
    end

    it "writes a full IRI when the local part is not a legal PN_LOCAL" do
      ex # register the prefix
      path = described_class.term(RDF::URI("https://example.com/ns#has.trailing."))

      expect(path.to_s).to eq("<https://example.com/ns#has.trailing.>")
    end

    it "raises rather than abbreviating away a space it cannot write either way" do
      ex
      path = described_class.term(RDF::URI("https://example.com/ns#has space"))

      expect { path.to_s }.to raise_error(ArgumentError, /IRIREF/)
    end
  end

  describe "immutability" do
    it "does not mutate an operand" do
      knows = foaf.knows
      _ = knows / ex.worksAt
      _ = +knows
      _ = ~knows

      expect(knows.to_s).to eq("foaf:knows")
    end

    it "does not mutate the vocabulary" do
      foaf.knows

      expect(foaf.name.to_s).to eq("foaf:name")
    end

    it "is frozen" do
      expect(foaf.knows).to be_frozen
    end
  end

  describe "equality" do
    it "is equal to a path that renders the same way" do
      expect(foaf.knows / ex.worksAt).to eq(foaf.knows / ex.worksAt)
    end

    it "is not equal to a differently grouped path" do
      expect(~ex.worksAt / ex.worksAt).not_to eq((ex.worksAt / ex.worksAt).inverse)
    end

    it "hashes with its rendering" do
      set = {(foaf.knows / ex.worksAt) => :yes}

      expect(set[foaf.knows / ex.worksAt]).to eq(:yes)
    end
  end

  describe "StringBuilder's method_missing" do
    it "is switched off, so a typo raises instead of becoming a token" do
      expect { foaf.knows.opts }.to raise_error(NoMethodError)
    end
  end

  describe "the vocabulary front end" do
    it "takes its prefix from an RDF::Vocabulary when none is given" do
      described_class.vocabulary(RDF)

      expect(PgRipple::Prefixes.registered).to include("rdf" => RDF.to_uri.to_s)
    end

    it "addresses a reserved name through #[]" do
      expect(ex[:class].to_s).to eq("ex:class")
    end

    it "refuses arguments, which would be a misread of the DSL" do
      expect { ex.worksAt(1) }.to raise_error(ArgumentError, /takes no arguments/)
    end
  end

  describe "#inspect" do
    it "shows the rendered path" do
      expect(foaf.knows.inspect).to eq('#<PgRipple::Path "foaf:knows">')
    end
  end
end

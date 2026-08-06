# frozen_string_literal: true

require "sparql"

require "pg_ripple/path"

# String equality against the README table is the acceptance criterion, but it
# only proves the gem emits the characters the spec wrote down. This file proves
# the characters *mean* what they are supposed to, by parsing each one with the
# `sparql` gem and comparing the resulting algebra.
#
# It is the only check that would have caught the precedence bug the phase was
# written around: `^(ex:worksAt/ex:worksAt)` is a perfectly valid path that
# renders, runs, and returns the wrong people.
RSpec.describe PgRipple::Handlers::SparqlPath do
  around do |example|
    registered = PgRipple::Prefixes.registered
    PgRipple::Prefixes.clear!
    example.run
  ensure
    PgRipple::Prefixes.clear!
    registered.each { |prefix, expansion| PgRipple::Prefixes.register(prefix, expansion) }
  end

  let(:foaf) { PgRipple::Path.vocabulary("http://xmlns.com/foaf/0.1/", prefix: "foaf") }
  let(:ex) { PgRipple::Path.vocabulary("https://example.com/ns#", prefix: "ex") }
  let(:rdf) { PgRipple::Path.vocabulary(RDF) }

  # The SPARQL algebra of `<s> <path> ?o`, as an S-expression.
  def algebra_for(path)
    query = <<~SPARQL
      #{path.prefix_declarations}SELECT ?o WHERE { <https://example.com/s> #{path} ?o }
    SPARQL

    SPARQL.parse(query).to_sxp.gsub(/\s+/, " ")[/\(path .*?\) \?o\)/, 0]
  end

  matcher :parse_as do |expected|
    match { |path| algebra_for(path).include?(expected) }

    failure_message do |path|
      "expected #{path.to_s.inspect} to parse as #{expected}, got #{algebra_for(path)}"
    end
  end

  it "binds ^ to the left operand only, not to the whole sequence" do
    expect(~ex.worksAt / ex.worksAt).to parse_as("(seq (reverse ex:worksAt) ex:worksAt)")
  end

  it "binds ^ to the whole sequence when that is what was asked for" do
    expect((ex.worksAt / ex.worksAt).inverse)
      .to parse_as("(reverse (seq ex:worksAt ex:worksAt))")
  end

  it "binds unary + to the left operand only" do
    expect(+foaf.knows / ex.worksAt).to parse_as("(seq (path+ foaf:knows) ex:worksAt)")
  end

  it "gives / tighter binding than |, as Ruby does" do
    expect(foaf.knows / ex.worksAt | ex.colleague / ex.worksAt)
      .to parse_as("(alt (seq foaf:knows ex:worksAt) (seq ex:colleague ex:worksAt))")
  end

  it "groups an alternative used as a sequence step" do
    expect((foaf.knows | ex.colleague) / ex.worksAt)
      .to parse_as("(seq (alt foaf:knows ex:colleague) ex:worksAt)")
  end

  it "groups a sequence under a modifier" do
    expect((foaf.knows / ex.worksAt).one_or_more)
      .to parse_as("(path+ (seq foaf:knows ex:worksAt))")
  end

  # SPARQL's PathElt takes at most one PathMod, so the naive `foaf:knows+?`
  # is a parse error rather than a subtly different path.
  it "groups a modified path under a second modifier" do
    expect((+foaf.knows).opt).to parse_as("(path? (path+ foaf:knows))")
  end

  it "leaves an already-modified atom alone under ^" do
    expect(~+ex.manages).to parse_as("(reverse (path+ ex:manages))")
  end

  # `PathEltOrInverse ::= '^'? PathPrimary PathMod?` carries at most one '^',
  # so the stacked form the precedence rule used to emit — `^^ex:manages` — is
  # a syntax error, not a double inverse. This is the check that tells the two
  # apart.
  it "groups an inverse under a second inverse" do
    expect(~~ex.manages).to parse_as("(reverse (reverse ex:manages))")
  end

  it "parses a negated property set" do
    expect(!rdf.type).to parse_as("(notoneof rdf:type)")
  end

  it "parses a negated set of an inverse" do
    expect(!(~ex.manages)).to parse_as("(notoneof (reverse ex:manages))")
  end

  # A one-predicate path is not a `path` in the algebra at all — SPARQL folds it
  # back into an ordinary triple pattern, which is exactly why {PgRipple::Path#to_term}
  # exists.
  it "parses a path over a namespace with no prefix at all" do
    path = PgRipple::Path.term(RDF::URI("https://unregistered.example/p"))
    query = "SELECT ?o WHERE { <https://example.com/s> #{path} ?o }"

    expect(SPARQL.parse(query).to_sxp.gsub(/\s+/, " "))
      .to include("(bgp (triple <https://example.com/s> <https://unregistered.example/p> ?o))")
  end

  describe "the token contract" do
    it "refuses a token it did not put there itself" do
      expect { described_class.call([["knows", []]]) }
        .to raise_error(ArgumentError, /cannot render/)
    end

    it "refuses an operator it has no rendering for" do
      expect { described_class.call([:backslash]) }
        .to raise_error(ArgumentError, /no operator/)
    end
  end
end

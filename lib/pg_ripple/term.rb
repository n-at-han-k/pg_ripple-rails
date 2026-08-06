# frozen_string_literal: true

require "rdf"
require "rdf/ntriples"

module PgRipple
  # Moves RDF terms across the SQL boundary.
  #
  # pg_ripple speaks N-Triples at every edge. `insert_triple` and
  # `delete_triple` take N-Triples-formatted terms; `find_triples` returns them;
  # and every binding inside the `result` JSONB that `pg_ripple.sparql()` yields
  # is one too — an IRI arrives as `"<https://…>"`, a typed literal as
  # `"\"30\"^^<http://www.w3.org/2001/XMLSchema#integer>"`, a language-tagged
  # one as `"\"Alice\"@en"`, all under the variable's own key with no wrapper
  # object and no separate datatype key (`docs/probe-lateral-join.md` §d).
  #
  # So there is exactly one encoding to get right, and it is the one the `rdf`
  # gem already implements. Nothing in this gem builds a term with string
  # interpolation: {.serialize} escapes, which is what keeps a literal
  # containing `"` or `>` or a newline from ending the term early.
  #
  # @api private
  module Term
    # The angle brackets an IRI wears in N-Triples and does not wear as an
    # argument to pg_ripple's graph-scoped functions. See {.graph_argument}.
    ANGLE_BRACKETS = "<>"

    # Characters SPARQL 1.1's `IRIREF` production excludes:
    #
    #     IRIREF ::= '<' ([^<>"{}|^`\]-[#x00-#x20])* '>'
    #
    # N-Triples escapes them as `\uXXXX`; SPARQL has no `UCHAR` inside an
    # `IRIREF`, so the escaped form does not parse. Percent-encoding would
    # change the IRI, and RDF compares IRIs by string — there is nothing honest
    # to emit, so {.sparql} raises. Canonical home for the rule;
    # {PgRipple::Handlers::SparqlPath} reads it from here.
    FORBIDDEN_IN_IRIREF = /[\x00-\x20<>"{}|^`\\]/

    module_function

    # An RDF term as the N-Triples text pg_ripple expects.
    #
    # @param term [RDF::Term]
    # @return [String]
    def serialize(term)
      RDF::NTriples.serialize(term)
    end

    # An RDF term as SPARQL text, with no prefix declaration needed.
    #
    # Literals and blank nodes go through `#to_base` — ruby-rdf's N-Triples
    # writer — because SPARQL's string-literal production accepts both `ECHAR`
    # and `UCHAR`, so an N-Triples literal is always a legal SPARQL literal.
    # IRIs are the exception, and the only place this differs from
    # {.serialize}: SPARQL's `IRIREF` has no escape at all, so an IRI carrying
    # one of {FORBIDDEN_IN_IRIREF} raises rather than being written in a form
    # the server would either reject or silently read as a different IRI.
    #
    # Deliberately *not* abbreviated to a prefixed name: an update this gem
    # emits has to stand on its own, and a `foaf:` in it would depend on which
    # vocabulary gems the host application happened to load
    # (`docs/spec-corrections.md` §8).
    #
    # @param term [RDF::Term]
    # @return [String]
    # @raise [ArgumentError] when an IRI cannot be written in SPARQL at all
    def sparql(term)
      raise ArgumentError, "#{term.inspect} is not an RDF::Term" unless term.is_a?(RDF::Term)
      return term.to_base unless term.is_a?(RDF::URI)

      offender = FORBIDDEN_IN_IRIREF.match(term.to_s)
      if offender
        raise ArgumentError, "<#{term}> cannot be written in SPARQL: the character " \
          "#{offender[0].inspect} is excluded from SPARQL's IRIREF production and, unlike " \
          "N-Triples, SPARQL has no escape for it"
      end

      term.to_base
    end

    # An N-Triples term as read back from the server.
    #
    # Blank nodes are interned rather than parsed. `RDF::NTriples::Reader` keeps
    # a per-reader map of labels to fresh {RDF::Node}s, so decoding `_:b1` on
    # two rows with two readers would produce two distinct nodes and a
    # traversal would come apart at the join. `RDF::Node.intern` gives the same
    # object for the same label for the life of the process, which is what
    # "the same blank node" has to mean when the rows arrive one at a time.
    #
    # @param string [String, nil] an N-Triples term, or nil for an unbound
    #   variable (the `result` JSONB carries the key with a JSON null).
    # @return [RDF::Term, nil]
    def parse(string)
      return nil if string.nil?

      if string.start_with?("_:")
        RDF::Node.intern(string[2..])
      else
        RDF::NTriples::Reader.unserialize(string)
      end
    end

    # A graph IRI as the bare string pg_ripple's graph arguments want.
    #
    # Not every function agrees about angle brackets. `insert_triple` and
    # `delete_triple_from_graph` strip them before encoding the IRI into the
    # dictionary; `find_triples_in_graph`, `triple_count_in_graph` and
    # `clear_graph` do not, so a `<…>` handed to those encodes a *different*
    # dictionary entry than the one the write created and matches nothing.
    # Passing the bare IRI everywhere is the only form all of them read the
    # same way.
    #
    # @param graph [String, RDF::URI, nil]
    # @return [String, nil] nil for the default graph
    def graph_argument(graph)
      return nil if graph.nil?

      graph.to_s.delete_prefix("<").delete_suffix(">")
    end
  end
end

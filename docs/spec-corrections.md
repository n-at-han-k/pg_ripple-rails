# Corrections to the spec

The README is the design spec, and its output blocks are the acceptance criteria. These are
the places where those blocks do not match pg_ripple 0.128.0 as it actually behaves, found by
[`probe-results.md`](probe-results.md) — a live run against `ghcr.io/trickle-labs/pg-ripple`
reading signatures from `pg_proc` rather than from the upstream docs, which are stale.

Corrections 1–3 and 6–15 are settled: the extension, or the layer already in `lib/`, is the
authority. 4 and 5 are open decisions. 14 and 15 came from review of the built gem rather than
from the extension — they are places where the code was wrong and the README described the bug.

---

## 1. `pg_ripple.sparql()` returns `TABLE(result jsonb)`, so the lateral join changes shape

This one is load-bearing — it is the join the whole model-backed half of the gem rests on.

The spec emits:

```sql
JOIN LATERAL pg_ripple.sparql('SELECT ?iri WHERE { … }') AS g(iri text) ON g.iri = "people"."iri"
```

`src/sparql_api.rs:13` declares:

```rust
#[pg_extern]
fn sparql(query: &str) -> TableIterator<'static, (name!(result, pgrx::JsonB),)> {
```

One JSONB object per solution, under a fixed column named `result`. PostgreSQL rejects a
column definition list on a function with a declared composite return type — that syntax is
for `RETURNS SETOF record` — so `AS g(iri text)` is an error, not a mismatch. The real form:

```sql
SELECT "people".* FROM "people"
JOIN LATERAL (
  SELECT btrim(r.result ->> 'iri', '<>') AS iri
  FROM   pg_ripple.sparql('SELECT ?iri WHERE { … }') AS r
) g ON g.iri = "people"."iri"
WHERE "people"."active" = TRUE
ORDER BY "people"."name" ASC LIMIT 20
```

> **Amended by [`probe-lateral-join.md` §a and §d](probe-lateral-join.md).** The `btrim` is not
> cosmetic. An IRI binding arrives as `"<https://…>"` — an N-Triples term string, angle brackets
> included — so the form originally written here (`r.result ->> 'iri'` bare) runs without error
> and returns **zero rows**. Literals carry their datatype or language tag inside the same
> string (`"\"30\"^^<…#integer>"`, `"\"Alice\"@en"`) and must not be unwrapped this way; an
> unbound variable is present with JSON `null`.

Consequences to design around, none of them fatal:

- **Every projected variable needs an explicit `->>` and a cast.** The `#variables` call the
  spec already plans (`sparql` gem, read side) supplies the list; each becomes
  `r.result ->> 'name'`, with a cast where the value is not text. The `AS t(cols)` projection
  in the Dependencies section becomes a select list instead.
- **A JSONB solution has no SQL type information.** `Person.graph.where(age: 30..40)` compares
  in SPARQL, where the typing is RDF's, so this only bites when a graph value is projected
  into a SQL predicate. Keep comparisons on the SPARQL side.
- **Per-solution JSONB has a cost** at high fan-out — one object allocated per solution before
  the outer `WHERE` filters anything. This sharpens, rather than introduces, the cardinality
  warning already in "Where the abstraction leaks".

**SETTLED: `LIMIT` does not push through — the SPARQL string needs its own.**
[`probe-lateral-join.md` §b](probe-lateral-join.md) proves it twice over.
`src/sparql/mod.rs:63` is `pub fn sparql(query_text: &str) -> Vec<pgrx::JsonB>`, so the whole
solution set is built before PostgreSQL sees row 1; `sparql_api.rs` merely wraps that finished
`Vec` in a `TableIterator`. Measured on a 25 921-solution query with an outer `LIMIT 1`, the
Function Scan reports `rows=1` but takes **83 ms to produce that one row**; injecting `LIMIT 1`
into the SPARQL instead takes **2.1 ms**. `EXPLAIN`'s `actual rows` counts rows pulled by the
parent, not rows computed, so it looks like a pushdown until you read the timing.
`sparql_cursor()` does not help — it bounds memory, not latency (87 ms on the same query).

So the relation builder **must** inject `LIMIT`/`OFFSET` into the SPARQL, via an AST rewrite
through the `sparql` gem and never by appending text (the query may already carry one). It is
only sound to inject when nothing downstream of the lateral can remove rows: no outer `ORDER BY`,
no outer `WHERE` on a SQL column, no other join. `alice.network.where(active: true).limit(20)`
therefore cannot take an injected `LIMIT 20` — the SQL predicate would filter an
already-truncated 20 solutions and return fewer than 20 rows. Where injection is unsound the
traversal is unbounded and the outer `LIMIT` is pure client-side truncation; that is now a
measured hazard rather than a hypothetical one, and `+`/`*` paths make it worse (probe
"Additional findings §1": a cyclic `+` path enumerates paths, not nodes, and can exhaust temp
space returning 200 rows).

## 2. `load_rules` takes the program first

```sql
load_rules(rules text, rule_set text DEFAULT 'custom') RETURNS bigint
```

The upstream docs say `load_rules(name, program)`. Reversed. A `$1, $2` bind written from the
docs loads the *rule set name* as a Datalog program — and because a bare word is a parse
error, it fails loudly rather than silently, which is the only good news here.

The Datalog surface in the spec's "Datalog rules" section also needs adjusting: rules are RDF
triple patterns, not classical predicate terms. `manages(X, Z) :- manages(X, Y), manages(Y, Z).`
is rejected with `expected 3 terms in triple pattern, got 2`. The accepted form is

```
?x <ex:manages> ?z :- ?x <ex:manages> ?y , ?y <ex:manages> ?z .
```

which the spec's own expected output already matches. `Handlers::Datalog` must emit the ` , `
body separator and the trailing ` .`.

## 3. Endpoints are keyed by URL; views carry a schedule

- `register_endpoint(url, local_view_name, complexity, graph_iri)` and `remove_endpoint(url)`.
  There is no `name` argument anywhere in the endpoint API, and
  `_pg_ripple.federation_endpoints` is `PRIMARY KEY (url)`.
- `create_sparql_view(name, sparql, schedule DEFAULT '1s', decode DEFAULT false, immediate DEFAULT false)`.
  A SPARQL view is a scheduled, incrementally-maintained pg_trickle stream table, not a
  PostgreSQL view — so `schedule` and `decode` are part of the definition and must round-trip.
- There is no `list_prefixes()`; read `_pg_ripple.prefixes` directly.
- `list_rules()` and `list_sparql_views()` return a single `jsonb`, while `list_graphs()`,
  `list_shapes()`, `list_rule_sets()` and `list_endpoints()` return tables.

## 4. OPEN: two migration naming schemes

The spec writes `create_ruleset`, `create_shape`, `create_json_mapping`, `create_tenant`. The
migration layer already in `lib/` writes `create_ripple_rules`, `create_ripple_shapes`, and so
on, because **every** method mixed into `ActiveRecord::ConnectionAdapters::AbstractAdapter`
must be prefixed or it shadows `fx`'s same-named methods for the entire host application —
`pg_cron-rails` shipped that bug and broke `create_function` everywhere
([`reference-gem-structure.md`](reference-gem-structure.md)).

`create_shape` is the specific hazard: `fx` has no such method today, but the collision class
is real and the cost of being wrong is silent breakage in someone else's migrations.

Three ways out, in order of preference:

1. Keep `create_ripple_*` as the mixed-in names and expose the spec's shorter names only
   inside a `ripple do … end` migration block, which is a receiver we own.
2. Ship the short names and accept the risk, documenting it.
3. Ship both, with the short ones as aliases — worst option: doubles the collision surface.

## 5. OPEN: `create_sparql_view` is broken upstream for new names

pg_ripple 0.128.0 against pg_trickle 0.68.0 unconditionally calls
`pgtrickle.drop_stream_table` before creating, and pg_trickle raises a hard error when the
table is absent, which the Rust `let _ = Spi::run(…)` cannot swallow. So creating a view under
a name that does not already exist fails. pg_trickle also rejects a view whose query matches no
predicates present in the store, so feature specs must load fixtures before creating views.

Until this is fixed upstream, `create_ripple_sparql_view` should raise a clear error naming the
bug rather than silently pre-creating a placeholder stream table — a workaround that hard-codes
another extension's internals.

## 6. SETTLED: both dependencies are publishable, both are in the gemspec

- `string_builder` is published; 1.2.4 installs. Whether its handler API suits `PgRipple::Path`
  is still open — that is a phase-3 question, not a packaging one.
- `active-triples` 1.2.0's floors are permissive enough not to hold Rails back: `activemodel
  >= 3.0.0`, `activesupport >= 3.0.0`, `rdf >= 2.0.2, < 4.0`, `required_ruby_version >= 2.1.0`.
  Nothing there conflicts with Rails 8.1 or with `rdf` 3.3.4.
- `rdf 3.3.4`, `active-triples 1.2.0`, `sparql 3.3.2` and `string_builder 1.2.4` resolve
  together against Rails 8.0 and 8.1 — verified by `bundle lock`, not by reading. Each is
  written `"~> x.y", ">= x.y.z"`: `~>` alone would allow an older patch than the one the
  behaviour was read from, and an `=` pin would fight every host application's lockfile.
- `neighbor` is deliberately **not** a dependency. It is only needed by vector search, which
  no code in this gem has yet; a runtime dependency for an absent feature is a version
  constraint a host application pays for and gets nothing from. It goes in with the feature.

## 7. SETTLED: the install generator writes `db/ripple/*`, not `db/shapes` and `db/rules`

The README's "Install" listing shows

```
create  db/shapes/.keep
create  db/rules/.keep
```

but `PgRipple::Definition` — the lookup `create_ripple_shapes` and `create_ripple_rules`
already go through — puts every kind of document under one `db/ripple` directory, and says
why: "rules" and "views" are words Rails and other extensions also want, and a host
application running F(x) already has a `db/views` meaning something else entirely.

Generating the README's paths would create two directories nothing reads, and the first
migration to load a shape would fail to find its file. The generator emits the same four
files, under `db/ripple/shapes/` and `db/ripple/rules/`. The README's Install listing is
what should change.

## 8. SETTLED: string_builder 1.2.4 has no `handler` macro, and its `method_missing` is switched off

The README sketches the path builder as

```ruby
class PgRipple::Path < StringBuilder
  handler PgRipple::Handlers::SparqlPath
  def to_term = RDF::URI(to_s)
end
```

Three things in five lines do not survive contact with the gem or with SPARQL.

**`handler` does not exist.** string_builder 1.2.4 (`lib/string_builder.rb`) offers
`attr_accessor :concat_handler` and `initialize(&custom_concat)`, both per-instance. There is
no class macro anywhere in the gem. `PgRipple::Path.handler` is our own one-line macro over
that accessor, defined on a class we own, so the README's spelling works.

**`method_missing` is disabled on `Path`.** StringBuilder's whole idiom is that any unknown
method becomes a token: `builder.knows` records `["knows", []]`. On a property path that turns
`foaf.knows.opts` — a typo — into a silent extra token, and the query runs and returns the
wrong rows. Path tokens come only from the operators; unknown methods raise. The vocabulary
front end (`PgRipple::Path.vocabulary`) is where `foaf.knows` is resolved instead, and it
returns a *fresh* path each time, because a StringBuilder chain mutates in place and a
vocabulary that mutated would be single-use.

Related: the gem's `/` lives on `InnerStringBuilder` and only inside a `wrap { }` block, via
`OPERATOR_MAP`. Paths are built in class bodies, so `#/` is a real operator on `Path`. What is
actually used from string_builder is the token buffer and the `concat_handler` seam — which is
the part the README's design argument rests on.

**`to_term` cannot be `RDF::URI(to_s)`.** `RDF::URI("foaf:knows+")` constructs happily; it is a
relative IRI that means nothing, and the failure surfaces much later as a triple written
against a predicate no query looks for. `#to_term` raises `PgRipple::NotAPredicate` unless the
path is a single predicate.

### Precedence is settled at build time, not in the handler

`~ex.worksAt / ex.worksAt` must render `^ex:worksAt/ex:worksAt`. `^(ex:worksAt/ex:worksAt)` is
also valid SPARQL, also parses, also runs — and returns the wrong colleagues. Ruby binds unary
`~` and unary `+` tighter than `/`, which is tighter than `|`; SPARQL's grammar agrees, so the
mapping is faithful as long as each path knows its own precedence and parenthesises operands
that bind looser than the operator needs. The handler then renders a flat token stream.

One level of that ordering is easy to miss: `PathElt ::= PathPrimary PathMod?` carries **at
most one** modifier, so `a+?` is a syntax error and `(foaf.knows+).opt` must emit
`(foaf:knows+)?`. `PathEltOrInverse` therefore sits *below* `PathPrimary` in the precedence
table. `spec/pg_ripple/handlers/sparql_path_spec.rb` parses every emitted path with the
`sparql` gem and asserts the resulting algebra, which is the only check that distinguishes
"renders the right characters" from "means the right thing".

### `RDF::URI#to_base` is N-Triples, and SPARQL's `IRIREF` is narrower

The spec is right that leaves must go through `#to_base` rather than `#to_s` — that is what
stops a `>` inside an IRI from closing the term early. But `#to_base` closes it by emitting an
N-Triples `>` escape, and SPARQL 1.1's `IRIREF` production has no `UCHAR`:

```
IRIREF ::= '<' ([^<>"{}|^`\]-[#x00-#x20])* '>'
```

so the escaped form does not parse (confirmed against `sparql` 3.3.2). Percent-encoding would
change the IRI, and RDF compares IRIs by string. There is nothing honest to emit, so
`Handlers::SparqlPath` raises naming the offending character.

### The prefix registry lives in the process, not the database

`foaf:knows` needs somewhere to say that `foaf:` means `http://xmlns.com/foaf/0.1/`.
`_pg_ripple.prefixes` is the wrong place: a path is a value built in a class body at boot,
before any connection exists, and `foaf.knows.to_s` cannot open a transaction.
`PgRipple::Prefixes` is a process-local registry that falls back to `RDF::Vocabulary`'s global
one for the well-known vocabularies, with local registrations winning.

The consequence is that the *same* path renders as `foaf:knows` in a process that loaded
`rdf-vocab` and as `<http://xmlns.com/foaf/0.1/knows>` in one that did not. Both are correct
only if the query carries a `PREFIX` line for each prefix the path actually used — so
`Path#prefixes` and `Path#prefix_declarations` exist, and the query builder must use them
rather than assume a fixed header. `create_ripple_prefix` and `PgRipple::Prefixes.register`
are deliberately uncoupled: the first affects how the server parses SPARQL, the second affects
what this gem emits, and a self-contained query needs neither.

## 9. SETTLED: `ActiveTriples::RDFSource` cannot be included into an ActiveRecord model

The README says the `property` DSL "is ActiveTriples' `RDFSource`", and the Dependencies
section says the surface used is four modules mixed in. It cannot be mixed in. Measured
against `active-triples` 1.2.0 and `activerecord` 8.1.3, on a real `people` table:

| step | result |
| --- | --- |
| `Person.include ActiveTriples::RDFSource` | succeeds — **silently** |
| `Person.property :name, predicate: foaf.name` | `ArgumentError: name is a keyword and not an acceptable property name.` |
| `Person.new(name: "Alice")` | `TypeError: #<Person…> is immutable` |
| `Person.first.attributes` | `{"id" => "g1168", "role" => []}` — the row's attributes are gone |
| `Person.first == Person.first` | `false` |

Each has a specific cause, and none is fixable from outside the library:

- `Properties::ClassMethods#protected_property_name?` refuses any name matching an existing
  instance method. On an ActiveRecord model *every mirrored column* is an existing instance
  method, so `property :name, from: :name` — the README's first line of DSL — is exactly the
  case that raises.
- `RDFSource#initialize` overrides `ActiveRecord::Core#initialize`, so `@attributes` is never
  built and the record never becomes usable.
- `RDFSource` defines `#attributes`, `#attributes=`, `#id`, `#reload`, `#type`, `#inspect`,
  `#==`, `#query`, `#each` and `#count`, and `Persistable` adds `#destroy` and `#persisted?`.
  Every one of those is ActiveRecord's. `#==` alone breaks record identity, which breaks
  `include?`, `uniq`, association targets and fixtures.

**`PgRipple::Node` therefore composes rather than includes.** Each model gets a generated
`ActiveTriples::Resource` subclass — `Person::GraphSource` — and a per-record instance of it
reachable as `#rdf_source`. The record delegates graph reads and writes to that object.

Nothing the README wanted from the library is lost: term coercion, multi-valued
`ActiveTriples::Relation` reads, `dump :ntriples`, and the `type:`/`property` configuration all
work on the companion. What is lost is only the spelling. The README's

```ruby
class PgRipple::Node
  include ActiveTriples::RDFSource
end
```

framing should be rewritten as composition, and the Dependencies note that the integration is
"kept narrow enough to vendor" is now the reason it does not need to be: the seam is one object
reference, not an inheritance chain.

Two smaller things fall out of the same reading:

- **ActiveTriples' `cast:` is not the README's `cast:`.** Theirs is a boolean that wraps
  resource-valued objects in an `RDFSource`; with it left on (the default), an `RDF::URI` you
  write reads back as an `ActiveTriples::Resource`. `PgRipple::Node` passes `cast: false` to
  ActiveTriples always, and uses `cast:` for the README's meaning — a class or callable that
  turns the Ruby value into a term.
- **`cast: RDF::URI` cannot produce the README's Turtle.** The example writes
  `email: "alice@example.com"` and expects `foaf:mbox <mailto:alice@example.com>`, but
  `RDF::URI("alice@example.com")` is a relative reference and `#valid?` is false. The callable
  form — `cast: ->(v) { RDF::URI("mailto:#{v}") }` — is what produces that Turtle. A cast that
  yields an invalid IRI raises `PgRipple::InvalidTerm` rather than writing a relative IRI that
  no query will ever match.
- **`get_values` on an undeclared property returns `[]`.** ActiveTriples does not raise there,
  so `PgRipple::UnknownProperty` is raised by `Node::Schema#fetch` before ActiveTriples is
  reached — the "typos raise" guarantee is ours, not the library's.

### A hazard with no library involvement: a module included into a model shadows its columns

```ruby
M = Module.new { def name = "FROM MODULE" }
Person.include M
Person.new(name: "col").name        # => "FROM MODULE"
Person.new(name: "col")[:name]      # => "col"
```

No warning, no `DangerousAttributeError` — ActiveRecord's generated attribute methods live in a
module included earlier, so anything included later wins. A graph-only `property :role` on a
table that has a `role` column would therefore replace the column reader in silence. `Node`
generates its accessors into an included module, so it checks: `validate_graph_properties!`
raises `PgRipple::PropertyCollision` for a graph-only property named after a column, and for a
`from:` naming a column that does not exist. The check is **lazy** — first accessor use, not
class-body time — because a class body is evaluated before `db:create` and must never touch the
connection.

## 10. SETTLED: `change_triples` watches the write, and `by:` counts facts

Two things about the README's

```ruby
it "writes only what changed" do
  alice = create(:person, role: "engineer")
  expect { alice.update!(role: "manager") }.to change_triples(by: 1)
end
```

do not survive being implemented.

**It cannot be a before/after count.** The diff and the whole-object rewrite the README
names as the anti-pattern leave the store in *identical* states — same triples, same
`count` — so nothing measured before and after the block can tell them apart, and the one
thing this example exists to test would pass either way. `change_triples` therefore
subscribes to an `ActiveSupport::Notifications` event, `write.pg_ripple`, that every
graph write publishes (`PgRipple::Persistence::WRITE`), and counts the writes themselves.
That event is also the seam a host application's audit or cache-expiry code can use
without patching the gem.

**`by: 1` is not a triple count.** Replacing `ex:role "engineer"` with `ex:role "manager"`
puts *two* triples on the wire — one retracted, one asserted — and changes the store's
triple count by *zero*. Neither number is 1. So `by:` counts **facts changed**: the
written triples deduplicated by subject and predicate, so a delete and an insert on the
same predicate are the one thing that actually happened. The README's `by: 1` is then
exactly right, and a strategy that rewrites a four-property subject reports 4 and fails
the example, which is the whole point. `inserting:` and `deleting:` give the raw triple
counts for when the shape of the write is what is under test.

A negated count (`not_to change_triples(by: 2)`) raises rather than passing: it is true of
a write of three facts, which is never what anyone means. `not_to change_triples` with no
arguments is the useful negation and is supported.

Two smaller notes from the same phase:

- **`graph` is additive.** The README declares one mapping across several calls —
  `graph type:, iri: do … end` in one place and `graph dependent: :nullify_references`
  or `graph persistence_strategy: …` on its own in another. A second call amends the
  schema rather than replacing it, and a subclass amending its parent's mapping gets a
  copy so the parent's is not rewritten for every sibling. A bare `graph` with neither
  options nor a block is still the `Person.graph.where(…)` relation entry point.
- **The baseline is what the store returned, not the graph after the read.**
  `ActiveTriples::RDFSource#initialize` writes the `rdf:type` statement that a
  `configure type:` declares, so a source built for a brand-new subject already asserts
  a triple the store has never seen. A `reload` that baselined on the merged graph
  swallowed exactly that triple and the type was never written. Found by a failing
  example, not by reading.

## 11. SETTLED: what `.graph` returns, what `where.not` means, and a test-harness hazard

The querying phase. Five things the README's "Graph associations" and "Querying" sections
do not say, four of them decisions and one of them a bug in the extension that any host
application's test suite will hit.

### `alice.network` is an `ActiveRecord::Relation`; `Person.graph` is a builder

The acceptance line works, exactly as written:

```ruby
alice.network.where(active: true).includes(:account).page(2)
```

is an `ActiveRecord::Relation`, Kaminari paginates it, and
`spec/pg_ripple/associations_spec.rb` runs that line with Kaminari loaded.
`graph_has_many` returns the relation itself — `Model.all` with the traversal joined on and
one extension module for `<<` and `#delete` — so nothing about it is a proxy.

`Person.graph` cannot be the same thing. `where` on it has to mean "filter by a graph
predicate", and an `ActiveRecord::Relation` already owns that name for the columns. So
`Person.graph` returns a `PgRipple::Relation`: a builder that forwards every
relation-*building* method (`order`, `includes`, `distinct`, `merge`, …) back into another
builder, and every *terminal* one (`to_a`, `count`, `pluck`, `each`, `page`) to the relation
it compiles. `#scope` forces it. The README's `# SPARQL, returns AR::Relation` is right about
what you get when you use it and wrong about `#class`.

`order` and `includes` deliberately keep the builder alive rather than dissolving into a
relation, because both of them change the answer to "may the `LIMIT` go into the SPARQL?" and
a chain that had already dissolved could not be asked.

`graph_has_one` returns the **record**, not a relation, because `alice.manager.name` is what
`has_one` means everywhere else in ActiveRecord. `#manager_relation` is the relation.

### `where.not(role: "contractor")` is `NOT EXISTS`, not `!=`

A graph property is a *set*. `FILTER(?role != "contractor")` is satisfied by a subject who is
a contractor *and* something else as well, and it excludes a subject with no role at all —
which is not what "not a contractor" says about someone with no role. `FILTER NOT EXISTS {
?iri ex:role "contractor" }` is the only rendering that is right for both, and it is what
`where(role: nil)` already had to be.

### Three things in the emitted SPARQL that the README's example SQL does not show

- **`SELECT DISTINCT`.** A property path with more than one route between the same two nodes
  yields the same `?iri` once per route, and each solution joins to the same row. Without
  `DISTINCT`, `alice.network` returns duplicate records on any graph with a diamond in it.
- **`PREFIX` lines.** README line 228 shows `foaf:knows+` with no `PREFIX` declaration, which
  is not a query any server can parse. Whether a path renders `foaf:knows` or
  `<http://xmlns.com/foaf/0.1/knows>` depends on what the host process registered (§8), so
  the header comes from `Path#prefixes` rather than from an assumption.
- **`LIMIT` inside the query, and only sometimes.** `pg_ripple.sparql()` materialises every
  solution before PostgreSQL sees row 1, so an outer `LIMIT` truncates finished work —
  measured at 40× (`probe-lateral-join.md` §b). It is pushed into the SPARQL only when
  nothing downstream can drop a row (no `WHERE`, `ORDER BY`, other join, group, having or
  eager load) **and** the traversal is closed over the model's own `rdf:type`, which
  `Model.graph` states and a bare path traversal does not. One residue is left, and it is
  documented rather than fixed: a subject of the right type whose row is missing still
  shortens the page. `PgRipple::Node` maintains that invariant — mint on create, erase on
  destroy — so the case is a row deleted behind the gem's back. An association's `#limit` is
  therefore never pushed down.

### `includes` forces the join literal to be readable as text

The traversal reaches SQL as an `Arel::Nodes::StringJoin` over a `BoundSqlLiteral`, so the
SPARQL travels as a bind parameter (`pg_ripple.sparql($1::text)`) rather than as quoted text
spliced into a join clause. But `ActiveRecord::Relation#references_eager_loaded_tables?` —
reached by any `includes`, which is the README's own example line — calls `String#scan` on a
`StringJoin`'s left side, and a `BoundSqlLiteral` is not a String. `PgRipple::Relation::BoundJoin`
adds `#scan` and `#blank?` over the *template*, where the placeholder is not a table name, so
ActiveRecord gets the same answer a plain string join would have given and the value still
travels as a bind.

### THE HAZARD: a rolled-back transaction poisons the dictionary cache for that connection

Not in the README, not in the probe, and it will bite every host application that tests with
transactional fixtures.

`probe-lateral-join.md` §e established that triples roll back with the row, and concluded that
a test suite should clean with a rollback. That is true of the *data* and false of the
*dictionary*: pg_ripple 0.128.0 keeps a per-backend cache mapping terms to dictionary ids, and
a `ROLLBACK` removes the dictionary rows without invalidating the cache. The next transaction
on that connection then writes triples against ids that no longer exist, and every query for
those terms returns **nothing** — silently, and only for the terms the rolled-back example was
the first to use, which is what makes it look like a flaky test rather than a bug.

Measured three ways, one insert-then-query per transaction, each rolled back:

| | round 1 | round 2 | round 3 |
| --- | --- | --- | --- |
| same connection, same terms | 1 | **0** | **0** |
| reconnect between rounds | 1 | 1 | 1 |
| fresh terms each round | 1 | 1 | 1 |

So the cache is per backend and the fix is to drop the connection.
`spec/support/database.rb` calls `PgRipple::TestHelpers.reset_dictionary_cache!` before each
`:database` example, which costs a few milliseconds and makes the suite deterministic. A host
application using Rails' `use_transactional_tests` needs the same thing.

**Now shipped and documented.** The first cut of this phase left the workaround inside the
gem's own suite and told host applications the opposite — README "Testing" read "same
connection, so nothing extra to clean up", and `PgRipple::TestHelpers` said a suite that
cleans "is working around a problem it does not have". Both were about the *data*, which is
right, and both read as being about the whole hazard, which is wrong. So:

- `PgRipple::TestHelpers.reset_dictionary_cache!` is a public module method (there is an
  instance-method spelling, `#ripple_reset_dictionary_cache!`, for a suite that includes the
  module), and the gem's own suite calls it rather than open-coding `disconnect!`.
- The README's "Testing" section shows the `before(:each)` line and says why.

It is deliberately **not** installed as a global hook by `require "pg_ripple/rspec"`.
Disconnecting a host application's connection pool before every example — including the ones
that never touch a database — is not a decision a gem gets to make on someone's behalf
without being asked.

---

## 12. SETTLED: the README's `colleagues` path is inverted

README, "Graph associations":

```ruby
graph_has_many :colleagues, path: ~ex.worksAt / ex.worksAt, class_name: "Person"
```

Read from a person, `^ex:worksAt` asks *who works at Alice*. Alice is not an employer, so the
first step of the sequence binds nothing and the association is the empty relation — for every
record, on every graph, forever. It is not a traversal that returns the wrong people; it is one
that cannot return anybody.

The path that means "colleagues" runs the other way: to the employer, then back.

```ruby
graph_has_many :colleagues, path: ex.worksAt / ~ex.worksAt, class_name: "Person"
```

Both are asserted live in `spec/acceptance/property_paths_spec.rb`: the corrected path returns
Alice's colleagues (including Alice, since she works where she works — `sh:not`-style exclusion
of the start node is not something a property path can express), and the README's spelling
returns `[]`.

`spec/dummy/app/models/person.rb` keeps the README's spelling on purpose. The README is the
acceptance criteria and the point of the dummy is to be what it describes; the spec is where
the disagreement is recorded, not the model. A host application should write the corrected one.

The direction is the only thing wrong with it. `~ex.worksAt / ex.worksAt` is a perfectly good
path, renders correctly, and parses in both SPARQL implementations — which is exactly why no
unit spec caught it and why it took a fixture with real employers to see.

---

## 13. SETTLED: `raise ActiveRecord::Rollback` needs `requires_new:` under a transactional suite

README, "Transactions", opens `ActiveRecord::Base.transaction` and ends with
`raise ActiveRecord::Rollback if over_quota?(account)`. That is correct at the top level of a
host application.

It is a no-op inside a test suite that wraps each example in a transaction — which is the very
suite the README's "Testing" section asks for two sections later. A nested
`ActiveRecord::Base.transaction` that did not ask for a savepoint is not a transaction at all;
Rails swallows `ActiveRecord::Rollback` there and rolls nothing back, so the example passes for
the wrong reason or fails confusingly.

`spec/acceptance/transactions_spec.rb` therefore writes `transaction(requires_new: true)`, and
says why in a comment. This is Rails' rule rather than anything to do with pg_ripple, and it is
worth a line in the README's "Testing" section because the two examples are printed nine
sections apart and are individually correct.

---

## 14. SETTLED: four defects found by review, and what the README now says instead

All four reproduced before they were fixed; the measurements below are the reproductions,
not the reasoning.

### `#inverse` parenthesises what it inverts

`PathEltOrInverse ::= '^'? PathPrimary PathMod?` carries **at most one** `'^'`, the same way
`PathElt` carries at most one `PathMod` (§8). An inverse already sits at `MOD` precedence, so
`tokens_at_least(MOD)` added no parentheses and the carets stacked: `(~~ex.manages).to_s` was
`"^^ex:manages"`, which `sparql` 3.3.2 refuses with *syntax error, expecting :IRIREF … (found
"^ex:manages ?x }")*. Reachable as `~~path` and as `path.inverse.inverse`, and the README
advertises `#inverse` on an arbitrary path.

`PgRipple::Path#~` now groups an inverse operand: `^(^ex:manages)`, which parses as
`(reverse (reverse ex:manages))`. The README's "Property paths" block prints that output.

### The lateral join alias is a digest, not a count

`pg_ripple_graph_#{scope.joins_values.size}` was computed against whatever scope the join was
being attached to — and `Definition#scope_for` always attaches to a fresh `target.all`, which
has none. So every association named its lateral `pg_ripple_graph_0`, and
`alice.friends.merge(alice.network)` — two ordinary relations, merged the ordinary way, which
is the "it really is an `ActiveRecord::Relation`" claim — died with
`PG::DuplicateAlias: table name "pg_ripple_graph_0" specified more than once`.

The alias is now `pg_ripple_graph_<16 hex of SHA256(sparql)>`. Two different traversals get
two different aliases; two *identical* traversals get the same alias and the same
`Arel::Nodes::StringJoin`, which `#joins!` (`self.joins_values |= args`) then deduplicates
into one join rather than colliding — verified, not assumed. It is also stable across calls,
so `#to_sql` stays comparable.

### A pushed-down bound leaves the SQL, and brings an `ORDER BY` with it

Two bugs in one place, and the second was hidden by the first.

`OFFSET` was applied twice — pushed into the SPARQL *and* left on the SQL. `LIMIT` is
idempotent there (the lateral already returns at most `n` rows) so nothing looked wrong until
someone paged. Measured on 60 rows: `Person.graph.limit(20)` returned 20 and
`Person.graph.limit(20).offset(20)` returned **0**. The SPARQL was right, the join yielded its
20 rows, and SQL's own `OFFSET 20` then discarded all of them. 40 of 60 records unreachable,
nothing raised. `PgRipple::Relation#sql_scope` now strips the offset whenever the bound went
into the query. The `LIMIT` is left on as a cheap backstop against a duplicated `iri`.

The pushed-down bound also carried no `ORDER BY`, so the page boundaries were undefined by
SPARQL — the very hazard `Query#order_by_subject` was written for and applied only to
`find_each`. `#sparql_for_scope` now orders whatever it slices. This is free of any conflict:
the bound is only pushed down when the caller asked for no SQL ordering of their own. It costs
a sort inside the extension, which is the price of a repeatable page.

Related, and now also true: an offset with **no** limit is pushed down too. Leaving it in SQL
meant paging an unordered traversal, which is the same defect one method call away.

### `create!` on a graph association links what it creates

`CollectionMethods` defined `<<` and `#delete` and left `create`, `create!` and `build` as the
plain relation's. `alice.friends.create!(name: "New")` therefore inserted a row, wrote no
triple, returned the record, and `alice.friends` stayed empty — a silent failure where
`has_many` would have linked. `#create` and `#create!` now assert the edge for everything that
persisted; a `#create` whose validations failed is left alone, since there is nothing to link
to.

`#build` and `#new` **raise** `NotImplementedError`. `has_many#build` links in memory by
setting a foreign key; a graph edge is a triple between two subject IRIs and an unsaved record
has none, so there is no in-memory link to make. Returning an unlinked record — what the plain
relation's `#build` did — is the silent version of that error.

---

## 15. SETTLED: `#lease_connection`, not `ActiveRecord::Base.connection`

Every graph read and write went through `connectable.connection`, which for the default
`connectable` (`ActiveRecord::Base`) is the deprecated permanent-checkout API. Under
`ActiveRecord.permanent_connection_checkout = :disallowed` — the setting Rails is moving
towards — the whole gem raised, measured on activerecord 8.0.5.1:

```
Person.create!            -> ActiveRecord::ActiveRecordError: Called deprecated
                             `ActiveRecord::Base.connection` method.
PgRipple.repository.count -> same
ActiveRecord::Base.with_connection { PgRipple.repository.count } -> same
```

The third line is the one that mattered: an application could not even scope around it. Under
`:deprecated` it pins a pool connection to the thread for the process lifetime.

Both `PgRipple::Repository#connection` and `PgRipple::Adapters::Postgres#connection` now use
`#lease_connection` where it exists and fall back to `#connection` on Rails 7.1, where it does
not and is not deprecated. It has to be a *lease* rather than a `with_connection` block:
pg_ripple is only transactional with the application's own writes when it runs on the
connection the application is already using, and a block is free to hand back a different one.
This is the API `spec/support/database.rb` was already using, so the gem was disagreeing with
its own suite.

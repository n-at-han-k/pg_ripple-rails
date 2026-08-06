# Corrections to the spec

The README is the design spec, and its output blocks are the acceptance criteria. These are
the places where those blocks do not match pg_ripple 0.128.0 as it actually behaves, found by
[`probe-results.md`](probe-results.md) — a live run against `ghcr.io/trickle-labs/pg-ripple`
reading signatures from `pg_proc` rather than from the upstream docs, which are stale.

Corrections 1–3 are settled: the extension is the authority. 4–6 are open decisions.

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
  SELECT r.result ->> 'iri' AS iri
  FROM   pg_ripple.sparql('SELECT ?iri WHERE { … }') AS r
) g ON g.iri = "people"."iri"
WHERE "people"."active" = TRUE
ORDER BY "people"."name" ASC LIMIT 20
```

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

Unverified and worth probing before phase 1 of the new build: whether the planner pushes a
`LIMIT` through the lateral, or materialises every solution first. If it materialises,
`.limit(20)` on a `+foaf.knows` path over a dense graph is a full traversal, and the SPARQL
string needs its own `LIMIT` injected — an AST rewrite the `sparql` gem can do.

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

## 6. OPEN: two dependencies to verify before committing to them

- `string_builder` — the spec cites `general-intelligence-systems/string_builder` with a
  `~> 1.0` constraint. Confirm it is published, and that the handler API matches what
  `PgRipple::Path` assumes.
- `active-triples ~> 1.2` — the spec already notes upstream activity is low. Check its Ruby
  and ActiveModel version floors against Rails 8.1 before it becomes load-bearing for
  `PgRipple::Node`.

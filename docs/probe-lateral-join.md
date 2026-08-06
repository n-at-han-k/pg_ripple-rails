# Probe: the lateral join

Phase 1. Settles the SQL shape that every model-backed query in the gem emits, before any Ruby
depends on it.

**Environment.** Throwaway container `pg-ripple-phase1-lateral` from
`ghcr.io/trickle-labs/pg-ripple:0.128.0`
(digest `sha256:3e57f93509e980e90f3ddd2e5993011789fea75d24f9bde10f8f6df73f4e0431`),
`--rm`, ephemeral port, no volume, no network attachment. PostgreSQL 18.4,
`pg_ripple` 0.128.0, `shared_preload_libraries = pg_ripple,pg_trickle`,
`temp_file_limit = 1GB` (see [Additional findings §1](#1-a-cyclic-knows-blows-up-temp-space)).
Container removed at the end of the phase.

**Headline results.**

| | Answer |
|---|---|
| (a) | The corrected lateral join runs — but **not as written in `spec-corrections.md` §1**: it returns **zero rows** because IRI bindings arrive wrapped in angle brackets. Unwrap and it is correct. |
| (b) | **`LIMIT` does not push through.** `pg_ripple.sparql()` materialises every solution first. The relation builder **must** inject `LIMIT` into the SPARQL string. |
| (c) | Once, if uncorrelated (`loops=1`); once per outer row if correlated (`loops=5`). |
| (d) | N-Triples term strings. IRIs are `<…>`; datatype and language tag are **inside the same string**, not separate keys. Unbound → JSON `null`. |
| (e) | Yes, both ways. `sparql_update()` and ordinary DML share the caller's transaction. |
| (f) | `sparql_cursor(query text) RETURNS TABLE(result jsonb)` exists. Same signature as `sparql()`. It bounds memory, not latency — it does not fix (b). |

**Fixture.** `people(id, iri UNIQUE, name, active)` plus a `foaf:knows` chain
`1 → 2 → 3 → 4 → 5` with an extra edge `1 → 5`, and one plain literal, one
`xsd:integer` literal and one `@en` literal on person 1.

```sql
CREATE EXTENSION pg_ripple;
CREATE TABLE people (
  id     bigserial PRIMARY KEY,
  iri    text NOT NULL UNIQUE,
  name   text NOT NULL,
  active boolean NOT NULL DEFAULT true
);
INSERT INTO people (iri, name, active) VALUES
  ('https://app.example.com/people/1', 'Alice', true),
  ('https://app.example.com/people/2', 'Bob',   true),
  ('https://app.example.com/people/3', 'Carol', true),
  ('https://app.example.com/people/4', 'Dave',  false),
  ('https://app.example.com/people/5', 'Erin',  true);
SELECT pg_ripple.insert_triple('<https://app.example.com/people/1>','<http://xmlns.com/foaf/0.1/knows>','<https://app.example.com/people/2>');
-- … 2→3, 3→4, 4→5, 1→5
SELECT pg_ripple.insert_triple('<https://app.example.com/people/1>','<http://xmlns.com/foaf/0.1/name>','"Alice"');
SELECT pg_ripple.insert_triple('<https://app.example.com/people/1>','<https://app.example.com/age>','"30"^^<http://www.w3.org/2001/XMLSchema#integer>');
SELECT pg_ripple.insert_triple('<https://app.example.com/people/1>','<https://app.example.com/label>','"Alice"@en');
```

---

## a. Does the corrected lateral join run and return the right rows?

**The shape is right; the join predicate is not.** `spec-corrections.md` §1's SQL executes
without error and returns **zero rows**. `result ->> 'iri'` is `<https://…>`, and
`people.iri` is `https://…`, so the equality never holds. One `btrim(…, '<>')` fixes it.

### A0 — the README's form is a hard error, as §1 says

```sql
SELECT "people".* FROM "people"
JOIN LATERAL pg_ripple.sparql(
  'SELECT ?iri WHERE { <https://app.example.com/people/1> <http://xmlns.com/foaf/0.1/knows>+ ?iri }'
) AS g(iri text) ON g.iri = "people"."iri";
```

```
ERROR:  a column definition list is only allowed for functions returning "record"
LINE 4: ) AS g(iri text) ON g.iri = "people"."iri";
               ^
```

### A1 — `spec-corrections.md` §1 verbatim: runs, returns nothing

```sql
SELECT "people".* FROM "people"
JOIN LATERAL (
  SELECT r.result ->> 'iri' AS iri
  FROM   pg_ripple.sparql(
    'SELECT ?iri WHERE { <https://app.example.com/people/1> <http://xmlns.com/foaf/0.1/knows>+ ?iri }'
  ) AS r
) g ON g.iri = "people"."iri"
WHERE "people"."active" = TRUE
ORDER BY "people"."name" ASC LIMIT 20;
```

```
 id | iri | name | active
----+-----+------+--------
(0 rows)
```

### A2 — why: the raw solutions

```sql
SELECT r.result FROM pg_ripple.sparql(
  'SELECT ?iri WHERE { <https://app.example.com/people/1> <http://xmlns.com/foaf/0.1/knows>+ ?iri }'
) AS r;
```

```
                    result
-----------------------------------------------
 {"iri": "<https://app.example.com/people/5>"}
 {"iri": "<https://app.example.com/people/2>"}
 {"iri": "<https://app.example.com/people/4>"}
 {"iri": "<https://app.example.com/people/3>"}
(4 rows)
```

### A3 — the working form

```sql
SELECT "people".* FROM "people"
JOIN LATERAL (
  SELECT btrim(r.result ->> 'iri', '<>') AS iri
  FROM   pg_ripple.sparql(
    'SELECT ?iri WHERE { <https://app.example.com/people/1> <http://xmlns.com/foaf/0.1/knows>+ ?iri }'
  ) AS r
) g ON g.iri = "people"."iri"
WHERE "people"."active" = TRUE
ORDER BY "people"."name" ASC LIMIT 20;
```

```
 id |               iri                | name  | active
----+----------------------------------+-------+--------
  2 | https://app.example.com/people/2 | Bob   | t
  3 | https://app.example.com/people/3 | Carol | t
  5 | https://app.example.com/people/5 | Erin  | t
(3 rows)
```

Correct: `foaf:knows+` from person 1 reaches {2,3,4,5}; Dave (4) is `active = false` and is
filtered by the outer `WHERE`.

### A4 — one-hop, no property path

```sql
SELECT "people".* FROM "people"
JOIN LATERAL (
  SELECT btrim(r.result ->> 'iri', '<>') AS iri
  FROM   pg_ripple.sparql(
    'SELECT ?iri WHERE { <https://app.example.com/people/1> <http://xmlns.com/foaf/0.1/knows> ?iri }'
  ) AS r
) g ON g.iri = "people"."iri"
ORDER BY "people"."name" ASC;
```

```
 id |               iri                | name | active
----+----------------------------------+------+--------
  2 | https://app.example.com/people/2 | Bob  | t
  5 | https://app.example.com/people/5 | Erin | t
(2 rows)
```

**Verdict: (a) passes, with one amendment.** The central claim of `spec-corrections.md` §1 —
that the lateral projects out of `TABLE(result jsonb)` rather than taking a column definition
list — is confirmed. Its example SQL is missing the term unwrap and must be amended; the
canonical projection for an IRI-valued variable `v` is

```sql
btrim(r.result ->> 'v', '<>')
```

See [(d)](#d-what-is-actually-in-resultkey) for literals, which must **not** be unwrapped this
way.

---

## b. Does an outer `LIMIT` push through the lateral?

**No. `pg_ripple.sparql()` materialises every solution before returning its first row.**
This is settled both by source and by measurement.

### Source

`src/sparql_api.rs:13` hands `TableIterator` a fully-built `Vec`:

```rust
fn sparql(query: &str) -> TableIterator<'static, (name!(result, pgrx::JsonB),)> {
    let rows = crate::sparql::sparql(query);
    TableIterator::new(rows.into_iter().map(|r| (r,)))
}
```

and `src/sparql/mod.rs:63` is

```rust
pub fn sparql(query_text: &str) -> Vec<pgrx::JsonB> {
```

There is no lazy path. The `Vec` is complete before PostgreSQL sees row 1.

### Measurement

`EXPLAIN ANALYZE`'s `actual rows` on a Function Scan counts rows *pulled by the parent*, not
rows *computed*, so it looks like a pushdown until you read the timing. Fixture: a query with
25 921 solutions (a cross product of two `foaf:knows` patterns over the 156-node tree fixture),
and the outer query asks for exactly one row.

```sql
-- B6: how many solutions the query has
SELECT count(*) AS solutions FROM pg_ripple.sparql(
 'SELECT ?a ?b ?c ?d WHERE { ?a <http://xmlns.com/foaf/0.1/knows> ?b .
                             ?c <http://xmlns.com/foaf/0.1/knows> ?d }') r;
```

```
 solutions
-----------
     25921
Time: 108.021 ms
```

```sql
-- B7: outer LIMIT 1
EXPLAIN (ANALYZE, COSTS OFF, BUFFERS OFF)
SELECT "people".* FROM "people"
JOIN LATERAL (
  SELECT btrim(r.result ->> 'a', '<>') AS iri
  FROM pg_ripple.sparql(
   'SELECT ?a ?b ?c ?d WHERE { ?a <http://xmlns.com/foaf/0.1/knows> ?b .
                               ?c <http://xmlns.com/foaf/0.1/knows> ?d }') r
) g ON g.iri = "people"."iri"
LIMIT 1;
```

```
 Limit (actual time=82.970..82.971 rows=1.00 loops=1)
   ->  Nested Loop (actual time=82.969..82.970 rows=1.00 loops=1)
         ->  Function Scan on sparql r (actual time=82.930..82.930 rows=1.00 loops=1)
         ->  Index Scan using people_iri_key on people (actual time=0.031..0.031 rows=1.00 loops=1)
               Index Cond: (iri = btrim((r.result ->> 'a'::text), '<>'::text))
               Index Searches: 1
 Planning Time: 0.177 ms
 Execution Time: 83.475 ms
```

`rows=1.00`, but **`actual time=82.930..82.930` for the first row** — 83 ms to produce one row
from a scan that "returned" one row. That 83 ms is the other 25 920 solutions being built and
thrown away.

```sql
-- B8: identical, with LIMIT 1 injected into the SPARQL string
EXPLAIN (ANALYZE, COSTS OFF, BUFFERS OFF)
SELECT "people".* FROM "people"
JOIN LATERAL (
  SELECT btrim(r.result ->> 'a', '<>') AS iri
  FROM pg_ripple.sparql(
   'SELECT ?a ?b ?c ?d WHERE { ?a <http://xmlns.com/foaf/0.1/knows> ?b .
                               ?c <http://xmlns.com/foaf/0.1/knows> ?d } LIMIT 1') r
) g ON g.iri = "people"."iri"
LIMIT 1;
```

```
 Limit (actual time=2.091..2.092 rows=1.00 loops=1)
   ->  Nested Loop (actual time=2.091..2.091 rows=1.00 loops=1)
         ->  Function Scan on sparql r (actual time=2.076..2.076 rows=1.00 loops=1)
         ->  Index Scan using people_iri_key on people (actual time=0.011..0.011 rows=1.00 loops=1)
               Index Cond: (iri = btrim((r.result ->> 'a'::text), '<>'::text))
               Index Searches: 1
 Planning Time: 0.101 ms
 Execution Time: 2.106 ms
```

**83.475 ms → 2.106 ms, a 40× difference on the same result.**

A `LIMIT` placed directly on the function scan behaves the same way — the plan node disappears
but the work does not:

```sql
-- B3: 156-solution path query, LIMIT 1 on the function scan
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, BUFFERS OFF)
SELECT r.result FROM pg_ripple.sparql(
  'SELECT ?iri WHERE { <https://app.example.com/t/0> <http://xmlns.com/foaf/0.1/knows>+ ?iri }') r
LIMIT 1;
```

```
 Limit (actual rows=1.00 loops=1)
   ->  Function Scan on sparql r (actual rows=1.00 loops=1)
 Execution Time: 1.078 ms
```

versus with the LIMIT in the SPARQL (B4), `Execution Time: 0.862 ms` and no `Limit` node.

### Decision this forces

**The relation builder must inject `LIMIT` (and `OFFSET`) into the SPARQL string**, as
`spec-corrections.md` §1 suspected. Three constraints follow:

1. It is only sound to inject when the outer query's row order is decided by the SPARQL side —
   i.e. when there is no outer `ORDER BY`, no outer `WHERE` on a SQL column, and no other join
   that can filter rows out. `alice.network.where(active: true).limit(20)` **cannot** get
   `LIMIT 20` in its SPARQL: the SQL `active = TRUE` predicate would then be applied to an
   already-truncated 20 solutions and silently return fewer than 20 rows. In the A3 fixture that
   is exactly the Dave case.
2. Where injection is unsound, the SPARQL runs unbounded and the outer `LIMIT` is a pure client
   -side truncation. That is the cardinality hazard "Where the abstraction leaks" describes, and
   it is now measured, not hypothetical.
3. Inject through the `sparql` gem's algebra (an AST rewrite), never by appending text — a query
   may already carry `LIMIT`/`OFFSET`, and `SELECT … } LIMIT 5 LIMIT 20` is a parse error.

---

## c. Is the lateral re-executed per outer row?

**Uncorrelated: once. Correlated: once per outer row.** The planner decides, and it decides on
whether the SPARQL text depends on an outer column.

### C1 — uncorrelated

```sql
EXPLAIN (ANALYZE, COSTS OFF, BUFFERS OFF)
SELECT p.id FROM (SELECT * FROM people WHERE id <= 5) p
JOIN LATERAL (
  SELECT btrim(r.result ->> 'iri', '<>') AS iri
  FROM pg_ripple.sparql(
    'SELECT ?iri WHERE { <https://app.example.com/t/0> <http://xmlns.com/foaf/0.1/knows>+ ?iri }') r
) g ON g.iri = p.iri;
```

```
 Hash Join (actual time=3.049..3.050 rows=0.00 loops=1)
   Hash Cond: (btrim((r.result ->> 'iri'::text), '<>'::text) = people.iri)
   ->  Function Scan on sparql r (actual time=2.966..2.972 rows=156.00 loops=1)
   ->  Hash (actual time=0.022..0.022 rows=5.00 loops=1)
         ->  Seq Scan on people (actual time=0.008..0.020 rows=5.00 loops=1)
               Filter: (id <= 5)
               Rows Removed by Filter: 157
 Execution Time: 3.119 ms
```

`loops=1`. Not only is it evaluated once, the planner does not even keep it a nested loop — the
`LATERAL` is decorative and it becomes a hash join with the graph on the build side.

### C2 — correlated (SPARQL text built from `p.iri`)

```sql
EXPLAIN (ANALYZE, COSTS OFF, BUFFERS OFF)
SELECT p.id, g.iri FROM (SELECT * FROM people WHERE id <= 5) p
JOIN LATERAL (
  SELECT btrim(r.result ->> 'iri', '<>') AS iri
  FROM pg_ripple.sparql(
    format('SELECT ?iri WHERE { <%s> <http://xmlns.com/foaf/0.1/knows> ?iri }', p.iri)) r
) g ON true;
```

```
 Nested Loop (actual time=0.515..1.900 rows=5.00 loops=1)
   ->  Seq Scan on people (actual time=0.007..0.015 rows=5.00 loops=1)
         Filter: (id <= 5)
         Rows Removed by Filter: 157
   ->  Function Scan on sparql r (actual time=0.374..0.374 rows=1.00 loops=5)
 Execution Time: 1.910 ms
```

`loops=5` — one SPARQL execution per outer row, each a full parse-plan-execute of a new query
string. Rows are per-subject, as intended:

```
 id |               iri
----+----------------------------------
  1 | https://app.example.com/people/2
  1 | https://app.example.com/people/5
  2 | https://app.example.com/people/3
  3 | https://app.example.com/people/4
  4 | https://app.example.com/people/5
```

### C4 — uncorrelated, forced into a nested loop by an outer `LIMIT`

```
 Limit (actual time=1.504..1.505 rows=0.00 loops=1)
   ->  Nested Loop (actual time=1.503..1.504 rows=0.00 loops=1)
         Join Filter: (people.iri = btrim((r.result ->> 'iri'::text), '<>'::text))
         Rows Removed by Join Filter: 780
         ->  Function Scan on sparql r (actual time=1.203..1.209 rows=156.00 loops=1)
         ->  Materialize (actual time=0.000..0.000 rows=5.00 loops=156)
```

Still `loops=1` on the function scan; PostgreSQL puts the SRF on the *outer* side and
materialises the table instead. So an uncorrelated lateral is safe from repeated evaluation
regardless of join shape.

### Decision this forces

**Emit uncorrelated laterals.** `PgRipple::Person.graph.where(…)` and
`alice.network` both bind a *known* subject IRI at build time, so the SPARQL string is a
constant from SQL's point of view and this is the default. A correlated form (one SPARQL query
per outer row) is what a naive `graph_has_many` preload would produce, and is the N+1 this
gem's `graph_includes` exists to avoid — out of scope for this slice, but the measurement is
why it matters.

---

## d. What is actually in `result ->> key`?

**Every value is an N-Triples term string.** There is no structure, no type information, and no
separate keys for datatype or language. `jsonb_typeof` is `string` for every binding of every
kind.

### D1 — IRI binding

```sql
SELECT jsonb_pretty(r.result) FROM pg_ripple.sparql(
  'SELECT ?iri WHERE { <https://app.example.com/people/1> <http://xmlns.com/foaf/0.1/knows> ?iri }'
) AS r;
```

```json
{
    "iri": "<https://app.example.com/people/2>"
}
{
    "iri": "<https://app.example.com/people/5>"
}
```

**Wrapped in angle brackets.** This is the finding that breaks `spec-corrections.md` §1's SQL.

### D2 — plain literal, typed literal, language-tagged literal

```sql
SELECT jsonb_pretty(r.result) FROM pg_ripple.sparql(
  'SELECT ?name ?age ?label WHERE {
     <https://app.example.com/people/1> <http://xmlns.com/foaf/0.1/name> ?name ;
       <https://app.example.com/age> ?age ;
       <https://app.example.com/label> ?label }'
) AS r;
```

```json
{
    "age": "\"30\"^^<http://www.w3.org/2001/XMLSchema#integer>",
    "name": "\"Alice\"",
    "label": "\"Alice\"@en"
}
```

The datatype IRI and the language tag are **inside the string**, in N-Triples syntax, under the
variable's own key. There is no `"age_datatype"`, no `{"value":…,"datatype":…}` object. The
lexical form is wrapped in escaped double quotes.

### D3 — `jsonb_typeof` of every binding

```sql
SELECT k, v, jsonb_typeof(v) AS jsonb_type
FROM pg_ripple.sparql('SELECT ?name ?age ?label ?iri WHERE { … }') AS r,
     LATERAL jsonb_each(r.result) AS e(k, v)
ORDER BY k;
```

```
   k   |                          v                           | jsonb_type
-------+------------------------------------------------------+------------
 age   | "\"30\"^^<http://www.w3.org/2001/XMLSchema#integer>" | string
 iri   | "<https://app.example.com/people/5>"                 | string
 label | "\"Alice\"@en"                                       | string
 name  | "\"Alice\""                                          | string
```

An `xsd:integer` is a JSON *string*, so `(result ->> 'age')::int` fails — the text is
`"30"^^<…integer>`, not `30`. This is the concrete form of §1's "a JSONB solution has no SQL
type information".

### D4 — mixed object positions in one query

```sql
SELECT jsonb_pretty(r.result) FROM pg_ripple.sparql(
  'SELECT ?p ?o WHERE { <https://app.example.com/people/1> ?p ?o }') AS r;
```

```json
{ "o": "<https://app.example.com/people/2>",                "p": "<http://xmlns.com/foaf/0.1/knows>" }
{ "o": "<https://app.example.com/people/5>",                "p": "<http://xmlns.com/foaf/0.1/knows>" }
{ "o": "\"Alice\"",                                         "p": "<http://xmlns.com/foaf/0.1/name>" }
{ "o": "\"30\"^^<http://www.w3.org/2001/XMLSchema#integer>", "p": "<https://app.example.com/age>" }
{ "o": "\"Alice\"@en",                                      "p": "<https://app.example.com/label>" }
```

The same key carries IRIs and literals in different solutions, so unwrapping must be decided
per value, not per column.

### D5 — `ASK`

```json
{
    "result": "true"
}
```

Under the key `result` — which collides with the column name. `sparql_ask()` returns a plain
`boolean` and should be preferred.

### D6 — unbound variable

```sql
SELECT jsonb_pretty(r.result) FROM pg_ripple.sparql(
  'SELECT ?iri ?missing WHERE {
     <https://app.example.com/people/1> <http://xmlns.com/foaf/0.1/knows> ?iri .
     OPTIONAL { ?iri <https://app.example.com/nosuchpredicate> ?missing } }') AS r;
```

```json
{
    "iri": "<https://app.example.com/people/2>",
    "missing": null
}
```

The key is **present** with JSON `null`. So `result ->> 'v' IS NULL` distinguishes unbound, and
`result ? 'v'` does not.

### D7 — a literal whose lexical form contains angle brackets

```sql
SELECT pg_ripple.insert_triple('<https://app.example.com/people/1>','<https://app.example.com/note>','"<not an iri>"');
SELECT r.result ->> 'o'              AS raw,
       btrim(r.result ->> 'o', '<>') AS btrim_unwrap
FROM pg_ripple.sparql('SELECT ?o WHERE { <https://app.example.com/people/1> <https://app.example.com/note> ?o }') r;
```

```
      raw       |  btrim_unwrap
----------------+----------------
 "<not an iri>" | "<not an iri>"
```

Safe: an N-Triples literal always begins with `"`, so `btrim(…, '<>')` cannot bite into it. The
guarded form is still clearer in generated SQL:

```sql
CASE WHEN left(x, 1) = '<' THEN substr(x, 2, length(x) - 2) ELSE x END
```

### D8 — blank node

```json
{
    "o": "_:b175"
}
```

Bare `_:label`, no wrapping. Labels are regenerated per store, not stable across databases.

### Decisions this forces

- **The join key projection is `btrim(r.result ->> 'iri', '<>')`**, not `r.result ->> 'iri'`.
  Fix `spec-corrections.md` §1.
- **Term decoding belongs in Ruby, on the value read back**, not in SQL casts. `PgRipple::Node`
  should parse the N-Triples term (`<…>` → `RDF::URI`, `"…"^^<…>` → typed `RDF::Literal`,
  `"…"@lang` → language literal, `_:…` → `RDF::Node`) — the `rdf` gem's N-Triples reader already
  does exactly this and is a pinned dependency.
- **Never project a graph literal into a SQL predicate.** `(result ->> 'age')::int` is a runtime
  error, not a cast. §1's advice to keep comparisons on the SPARQL side is not a preference; it
  is the only thing that works.

---

## e. Do `sparql_update()` and ordinary DML roll back together?

**Yes, both directions, and an error on either side aborts both.**
`sparql_update(query text) RETURNS bigint` runs entirely inside the caller's transaction.

### E1 — ROLLBACK

```sql
BEGIN;
  INSERT INTO people (iri, name, active) VALUES ('https://app.example.com/people/rb', 'Rollback', true);
  SELECT pg_ripple.sparql_update(
    'INSERT DATA { <https://app.example.com/people/rb> <http://xmlns.com/foaf/0.1/knows> <https://app.example.com/people/1> }');
  SELECT count(*) AS sql_rows_in_txn FROM people WHERE iri = 'https://app.example.com/people/rb';
  SELECT count(*) AS triples_in_txn FROM pg_ripple.sparql(
    'SELECT ?o WHERE { <https://app.example.com/people/rb> <http://xmlns.com/foaf/0.1/knows> ?o }') r;
ROLLBACK;
```

```
 sparql_update
---------------
             1

 sql_rows_in_txn      triples_in_txn
-----------------    ----------------
               1                   1
```

after `ROLLBACK`:

```
 sql_rows_after_rollback      triples_after_rollback
-------------------------    ------------------------
                       0                           0
```

Both visible inside, both gone after. The graph write is visible to `sparql()` in the same
transaction before commit — read-your-writes holds.

### E2 — COMMIT

```
 sql_rows_after_commit      triples_after_commit
-----------------------    ----------------------
                     1                         1
```

### E3 — a SQL error *after* a successful `sparql_update` retracts the graph write

```sql
BEGIN;
  SELECT pg_ripple.sparql_update('INSERT DATA { <…/people/er> <…/knows> <…/people/1> }');
  INSERT INTO people (iri, name, active) VALUES ('https://app.example.com/people/1', 'DupIRI', true);
COMMIT;
```

```
 sparql_update
---------------
             1
ERROR:  duplicate key value violates unique constraint "people_iri_key"
DETAIL:  Key (iri)=(https://app.example.com/people/1) already exists.
ROLLBACK

 triples_after_failed_txn
--------------------------
                        0
```

### E4 — `DELETE DATA` rolls back too

```sql
BEGIN;
  SELECT pg_ripple.sparql_update('DELETE DATA { <…/people/cm> <…/knows> <…/people/1> }');
  SELECT count(*) AS triples_in_txn FROM pg_ripple.sparql('SELECT ?o WHERE { <…/people/cm> <…/knows> ?o }') r;
ROLLBACK;
```

```
 triples_in_txn              triples_after_rollback
----------------            ------------------------
              0                                   1
```

### Decision this forces

The README's "How writes work" claim holds without caveat: `alice.friends << bob` inside an
ActiveRecord transaction is atomic with the surrounding SQL, and needs no two-phase dance, no
`after_commit` hook and no compensating delete. This matches `probe-results.md` §c for the
schema-level functions and extends it to the data path.

---

## f. Does `sparql_cursor()` exist, and how is it called?

**Yes. Identical calling convention to `sparql()`.**

```sql
SELECT p.proname, pg_get_function_arguments(p.oid) AS args, pg_get_function_result(p.oid) AS result
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'pg_ripple' AND p.proname LIKE 'sparql%';
```

```
       proname        |                  args                        |       result
----------------------+----------------------------------------------+---------------------
 sparql               | query text                                   | TABLE(result jsonb)
 sparql_ask           | query text                                   | boolean
 sparql_cursor        | query text                                   | TABLE(result jsonb)
 sparql_cursor_jsonld | query text                                   | TABLE(chunk text)
 sparql_cursor_turtle | query text                                   | TABLE(chunk text)
 sparql_update        | query text                                   | bigint
 explain_sparql       | query text, format text DEFAULT 'text'::text  | text
 explain_sparql       | query text, "analyze" boolean                 | jsonb
```

One `text` argument, same `TABLE(result jsonb)` shape, so it is a drop-in replacement for
`sparql()` in the lateral — the same `->>` projection and the same `btrim` unwrap apply.

```sql
SELECT r.result FROM pg_ripple.sparql_cursor(
  'SELECT ?iri WHERE { <https://app.example.com/people/1> <http://xmlns.com/foaf/0.1/knows> ?iri }') r;
```

```
                    result
-----------------------------------------------
 {"iri": "<https://app.example.com/people/2>"}
 {"iri": "<https://app.example.com/people/5>"}
(2 rows)
```

### It bounds memory, not latency — it is not a fix for (b)

Same 25 921-solution query, same outer `LIMIT 1`:

```
 Limit (actual time=87.011..87.012 rows=1.00 loops=1)
   ->  Nested Loop (actual time=87.010..87.010 rows=1.00 loops=1)
         ->  Function Scan on sparql_cursor r (actual time=86.983..86.983 rows=1.00 loops=1)
         ->  Index Scan using people_iri_key on people (actual time=0.020..0.020 rows=1.00 loops=1)
 Execution Time: 87.524 ms
```

87.5 ms versus `sparql()`'s 83.5 ms. What the cursor makes lazy is *materialising the JSONB
results in the extension's memory* (`src/sparql/cursor.rs` opens a portal over the generated SQL
and fetches pages), not evaluating the query. The underlying SQL still runs to completion before
the first page comes back.

Page size is not `pg_ripple.export_batch_size` in any obvious way — the GUCs present are:

```
 pg_ripple.export_batch_size          | 10000
 pg_ripple.arrow_batch_size           | 1000
```

`export_batch_size` is the one the README names for `find_each`; it is the batch size for the
export path, and `sparql_cursor` is the streaming primitive underneath. Whether they are the
same knob was not established here and does not block the slice — `find_each(batch_size: n)`
should pass its own `n` through as SPARQL `LIMIT`/`OFFSET`, not rely on a GUC.

### Decision this forces

`find_each` should use `sparql_cursor()` for the memory bound the README promises, **and**
inject `LIMIT`/`OFFSET` per batch for the latency bound, subject to the soundness constraint in
(b). A cursor alone does not make `find_each` incremental.

---

## Additional findings

### 1. A cyclic `knows+` blows up temp space

The first fan-out fixture attempted was 200 nodes in a ring, each knowing its next 6 successors
mod 200 — 1 200 edges, and a transitive closure of exactly 200 nodes.

```sql
SELECT count(*) FROM pg_ripple.sparql(
  'SELECT ?iri WHERE { <https://app.example.com/n/0> <http://xmlns.com/foaf/0.1/knows>+ ?iri }') r;
-- ERROR:  could not write to file "base/pgsql_tmp/pgsql_tmp231.70": No space left on device
```

An acyclic version — 120 nodes, node *i* knows *i+1 … i+4*, 470 edges, closure 119 nodes — still
exceeded a 512 MB `temp_file_limit`:

```sql
-- ERROR:  temporary file size exceeds "temp_file_limit" (524288kB)
```

while the 156-node tree used for (b) and (c) (156 edges, out-degree 12, depth 2) completes the
same closure in 20 ms. So the cost is not in the number of reachable nodes; `+` on a graph with
many *distinct paths* between the same pair of endpoints enumerates paths, not nodes.

Consequences for the gem:

- **Set `temp_file_limit` in the test harness.** A feature spec with an unlucky fixture can fill
  the host disk. The probe container ran with `temp_file_limit = 1GB` after the first blowup.
- `+` and `*` paths need a documented warning stronger than the README's current one, and
  `graph_has_many … path: +foaf.knows` should be presented as a query that can be unboundedly
  expensive on a cyclic graph regardless of how few rows it returns.
- Combined with (b), this is the worst case: a `+` path whose SPARQL cannot take an injected
  `LIMIT` because an outer SQL predicate follows it.

### 2. `DROP EXTENSION pg_ripple CASCADE` then `CREATE EXTENSION` leaves the store broken

Recreating the extension in a live postmaster left `_pg_ripple.dictionary` empty while
`insert_triple` kept returning fresh ids, and the background worker logged

```
pg_ripple merge worker: merge cycle panicked (2): [16908420] relation "_pg_ripple.er_unresolved_entities" does not exist
pg_ripple merge worker: 3 consecutive errors, backing off for 60s (max 60s)
```

on a loop. Writes were accepted and never landed. **Test-suite consequence:** clean between
examples with a transaction rollback (which (e) proves is complete), never with
`DROP EXTENSION` / `CREATE EXTENSION`. If a suite must reset the store, restart the server.

### 3. `shared_preload_libraries` matters for the probe, and for CI

Starting the container with an extra `-c` argument replaces the image's default command and
silently drops `shared_preload_libraries = pg_ripple,pg_trickle`, after which every query warns:

```
WARNING:  pg_ripple: loaded without shared_preload_libraries; HTAP merge worker,
CONSTRUCT writeback, and dictionary cache are disabled.
```

Results in that mode are not representative. Set GUCs with `ALTER SYSTEM` + `pg_reload_conf()`
after startup instead, and have CI assert `SHOW shared_preload_libraries` before running specs.

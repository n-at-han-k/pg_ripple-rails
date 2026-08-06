# Probe results

Answers to [`WORKFLOW.md` section 7](../WORKFLOW.md#7-open-questions-to-settle-before-phase-3),
obtained by experiment rather than by reading the docs.

**Environment.** Throwaway container `pg-ripple-rails-probe` from
`ghcr.io/trickle-labs/pg-ripple:latest`
(digest `sha256:3e57f93509e980e90f3ddd2e5993011789fea75d24f9bde10f8f6df73f4e0431`,
built 2026-05-22). PostgreSQL 18.4 (Debian), `pg_ripple` 0.128.0, `pg_trickle` 0.68.0.
Container removed at the end of the phase.

Read [§0](#0-signatures-the-docs-get-wrong) first — several answers below only make sense once
you know the real function signatures. It is also the section with the most consequences for
phases 2–4.

---

## 0. Signatures the docs get wrong

`references/pg-ripple/docs/src/reference/sql-functions.md` is stale. The per-subsystem reference
pages (e.g. `reference/datalog.md`) are accurate. What the database actually exposes:

```sql
SELECT p.proname, pg_get_function_arguments(p.oid) AS args, pg_get_function_result(p.oid) AS result
FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'pg_ripple'
AND    p.proname IN ('create_graph','drop_graph','list_graphs','register_prefix',
                     'load_shacl','drop_shape','list_shapes','load_rules','drop_rules',
                     'list_rules','list_rule_sets','create_sparql_view','drop_sparql_view',
                     'list_sparql_views','register_endpoint','remove_endpoint','list_endpoints')
ORDER  BY p.proname;
```

```
      proname       |                              args                              |                result
--------------------+----------------------------------------------------------------+--------------------------------------
 create_graph       | graph_iri text                                                 | bigint
 create_sparql_view | name text, sparql text, schedule text DEFAULT '1s'::text,      | bigint
                    |   decode boolean DEFAULT false, immediate boolean DEFAULT false|
 drop_graph         | graph_iri text                                                 | bigint
 drop_rules         | rule_set text                                                  | bigint
 drop_shape         | shape_uri text                                                 | integer
 drop_sparql_view   | name text                                                      | boolean
 list_endpoints     |                                                                | TABLE(url, enabled, local_view_name, complexity)
 list_graphs        |                                                                | TABLE(graph_iri text)
 list_rule_sets     |                                                                | TABLE(rule_set, active, rule_count, created_at)
 list_rules         |                                                                | jsonb
 list_shapes        |                                                                | TABLE(shape_iri text, active boolean)
 list_sparql_views  |                                                                | jsonb
 load_rules         | rules text, rule_set text DEFAULT 'custom'::text                | bigint
 load_shacl         | data text                                                      | integer
 register_endpoint  | url text, local_view_name text DEFAULT NULL, complexity text    | void
                    |   DEFAULT NULL, graph_iri text DEFAULT NULL                    |
 register_prefix    | prefix text, expansion text                                    | void
 remove_endpoint    | url text                                                       | void
```

Five differences that change the gem's design:

1. **`load_rules(rules, rule_set)` — the document comes FIRST.** `sql-functions.md` documents
   `load_rules(name, program)`. The real order is reversed, and `rule_set` defaults to
   `'custom'`. A `$1, $2` bind written from the stale doc silently loads the *rule set name* as
   a Datalog program.
2. **Endpoint identity is the URL, not a name.** There is no `name` argument anywhere:
   `register_endpoint(url, …)`, `remove_endpoint(url)`, and
   `_pg_ripple.federation_endpoints` has `PRIMARY KEY (url)`. WORKFLOW.md §1's
   `register_endpoint(name, url)` / `remove_endpoint(name)` does not exist.
3. **`create_sparql_view` takes three more arguments** — `schedule` (default `'1s'`), `decode`,
   `immediate` — because a SPARQL view is a *scheduled, incrementally-maintained* pg_trickle
   stream table, not a plain PostgreSQL view. All three are part of the object's definition and
   are stored in the catalog, so all three must round-trip.
4. **There is no `list_prefixes()`.** Read `_pg_ripple.prefixes (prefix, expansion)` directly.
5. **`list_rules()` and `list_sparql_views()` return a single `JSONB` value**, not a table.
   `list_graphs()`, `list_shapes()`, `list_rule_sets()` and `list_endpoints()` return tables.

Datalog rules are RDF triple patterns, not classical predicate terms:

```sql
SELECT pg_ripple.load_rules('manages(X, Z) :- manages(X, Y), manages(Y, Z).', 'org_chart');
-- ERROR:  rule parse error: line 1: expected 3 terms in triple pattern, got 2: manages(X, Z)

SELECT pg_ripple.load_rules('?x <ex:manages> ?z :- ?x <ex:manages> ?y , ?y <ex:manages> ?z .', 'org_chart');
--  load_rules
-- ------------
--           2
```

Note the body separator is `,` and every rule ends in ` .`. The generator's `create_rules.erb`
template must use this syntax or every generated migration fails on first run.

---

## a. Is `load_shacl()` additive or replacing when a shape IRI is redefined?

**Replacing per shape IRI; additive across the shape set.** `_pg_ripple.shacl_shapes` has
`shape_iri` as its primary key and `load_shacl` upserts, so a redefinition overwrites the whole
JSON document for that IRI. Properties are *not* merged.

```sql
-- A1: PersonShape with two properties
SELECT pg_ripple.load_shacl($ttl$
@prefix sh: <http://www.w3.org/ns/shacl#> .
@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
@prefix ex: <https://example.org/> .
ex:PersonShape a sh:NodeShape ;
    sh:targetClass ex:Person ;
    sh:property [ sh:path ex:name  ; sh:minCount 1 ; sh:datatype xsd:string ] ;
    sh:property [ sh:path ex:email ; sh:minCount 1 ; sh:datatype xsd:string ] .
$ttl$) AS shapes_loaded;
SELECT shape_iri, jsonb_array_length(shape_json->'properties') AS prop_count
FROM   _pg_ripple.shacl_shapes;
```

```
 shapes_loaded
---------------
             1

            shape_iri            | prop_count
---------------------------------+------------
 https://example.org/PersonShape |          2
```

```sql
-- A2: same IRI, one *different* property
SELECT pg_ripple.load_shacl($ttl$
@prefix sh: <http://www.w3.org/ns/shacl#> .
@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
@prefix ex: <https://example.org/> .
ex:PersonShape a sh:NodeShape ;
    sh:targetClass ex:Person ;
    sh:property [ sh:path ex:age ; sh:minCount 1 ; sh:datatype xsd:integer ] .
$ttl$) AS shapes_loaded;
SELECT shape_iri, jsonb_array_length(shape_json->'properties') AS prop_count
FROM   _pg_ripple.shacl_shapes;
```

```
            shape_iri            | prop_count
---------------------------------+------------
 https://example.org/PersonShape |          1
```

`prop_count` went 2 → 1: replaced, not merged. `ex:name` and `ex:email` are gone. Loading a
*different* IRI (A3) left `PersonShape` untouched and only bumped its own `updated_at`, so the
catalog as a whole is additive.

**Consequence for `update_ripple_shapes`.** WORKFLOW.md worried that a merge would force the gem
to `drop_shape` every IRI in the old version first. It does not — for IRIs present in **both**
versions the upsert is already correct. But one gap remains: an IRI the **old** file declared and
the **new** one does not is *orphaned*, still active, and still validating. The catalog cannot
say which file a shape came from — `shacl_shapes` has no provenance column, and D3 below shows a
multi-shape document is split into one independent row per shape with no grouping key. So
`update_ripple_shapes` cannot drop orphans without knowing the old file's IRIs.

Cheapest correct approach, and no Turtle parser needed: `update_ripple_shapes` reads the
**previous version's definition file**, which the gem already has on disk, and matches
`^\s*(\S+:\S+|<[^>]+>)\s+a\s+sh:NodeShape` against it to collect declared IRIs, then
`drop_shape`s any that the new version does not declare. It runs inside the migration's
transaction (see §c), so a wrong guess rolls back. Ask upstream for
`load_shacl(turtle, replace := true)` and a `source` column on `shacl_shapes` regardless.

---

## b. Does `load_rules()` replace a same-named rule set, or append?

**Replaces.** The whole rule set is deleted and re-inserted.

```sql
-- B1: two rules into org_chart
SELECT pg_ripple.load_rules($dl$
?x <ex:manages> ?z :- ?x <ex:manages> ?y , ?y <ex:manages> ?z .
?x <ex:colleague> ?y :- ?z <ex:manages> ?x , ?z <ex:manages> ?y .
$dl$, 'org_chart') AS rules_loaded;
SELECT * FROM pg_ripple.list_rule_sets();
```

```
 rules_loaded
--------------
            2

 rule_set  | active | rule_count |     created_at
-----------+--------+------------+---------------------
 org_chart | t      |          2 | 2026-08-06 13:32:04
```

```sql
-- B2: same name, one different rule
SELECT pg_ripple.load_rules($dl$
?x <ex:reports_to> ?y :- ?y <ex:manages> ?x .
$dl$, 'org_chart') AS rules_loaded;
SELECT id, rule_set, rule_text, stratum, active FROM _pg_ripple.rules ORDER BY id;
SELECT * FROM pg_ripple.list_rule_sets();
```

```
 rules_loaded
--------------
            1

 id | rule_set  |                   rule_text                   | stratum | active
----+-----------+-----------------------------------------------+---------+--------
  3 | org_chart | ?x <ex:reports_to> ?y :- ?y <ex:manages> ?x . |       0 | t

 rule_set  | active | rule_count |     created_at
-----------+--------+------------+---------------------
 org_chart | t      |          1 | 2026-08-06 13:32:04
```

Rows 1 and 2 are gone and the identity sequence advanced to 3 — a delete-then-insert, not an
append. `created_at` on `rule_sets` is preserved across the reload.

So `update_ripple_rules` is a **single `load_rules` call**. The `drop_rules` + `load_rules` pair
WORKFLOW.md proposed as the safe option is unnecessary, and is actively worse: it briefly leaves
the rule set absent, and `drop_rules` retracts materialised inferences that the reload would
otherwise have kept.

`rule_text` round-trips verbatim, one row per rule, ordered by `id`, so rule sets dump faithfully
by joining `_pg_ripple.rules` on `rule_set` — as WORKFLOW.md §4 already says.

---

## c. Do `create_sparql_view` / `drop_graph` / `load_shacl` roll back in an aborted transaction?

**Yes — all of them, fully. No function commits internally.** A single transaction created a
graph (with a triple), a shape, a rule set, a prefix, an endpoint and a SPARQL view, and dropped
one of each of the baseline objects. After `ROLLBACK` the database was byte-identical to the
baseline.

```sql
BEGIN;
  SELECT pg_ripple.create_graph('https://example.org/rolledback');
  SELECT pg_ripple.insert_triple('<https://example.org/bob>','<https://example.org/name>','"Bob"',
                                 'https://example.org/rolledback');
  SELECT pg_ripple.load_shacl($ttl$ … ex:RolledBackShape … $ttl$);
  SELECT pg_ripple.load_rules('?a <ex:rb> ?b :- ?b <ex:rb> ?a .', 'rolledback_rules');
  SELECT pg_ripple.register_prefix('rb', 'https://example.org/rb#');
  SELECT pg_ripple.register_endpoint('https://wikidata.org/sparql');
  SELECT pgtrickle.create_stream_table(name => 'pg_ripple.rbview',
           query => 'SELECT id AS s FROM _pg_ripple.dictionary', schedule => '1s');
  SELECT pg_ripple.create_sparql_view('rbview',
           'PREFIX ex: <https://example.org/> SELECT ?s ?n WHERE { ?s ex:name ?n }');
  SELECT pg_ripple.drop_shape('https://example.org/BaselineShape');
  SELECT pg_ripple.drop_sparql_view('people');
  SELECT pg_ripple.drop_rules('org_chart');
  SELECT pg_ripple.remove_endpoint('https://dbpedia.org/sparql');
  SELECT pg_ripple.drop_graph('https://example.org/keepme');
ROLLBACK;
```

Inside the transaction every change was visible:

```
 graph_iri                          |  shape_iri                          | name   | endpoint url
------------------------------------+-------------------------------------+--------+-----------------------------
 <https://example.org/rolledback>   | https://example.org/RolledBackShape | rbview | https://wikidata.org/sparql
```

After `ROLLBACK`:

```
graphs:    <https://example.org/keepme>
shapes:    https://example.org/BaselineShape, .../OrgShape, .../PersonShape
views:     people
prefixes:  12 rows, 'rb' absent, 'keep' present
endpoints: https://dbpedia.org/sparql
rule sets: org_chart (1 rule)

backing relations for the rolled-back view:
 nspname | relname | relkind
---------+---------+---------
(0 rows)

 pgt_rbview_rows
-----------------
               0
```

The catalogs, the RDF triples, the dictionary entries, the pg_trickle stream table and its
backing relations all reverted. A transaction aborted by an error mid-way (`SELECT 1/0`) behaves
identically. Migrations wrapping these calls **are** atomic, and the README needs no caveat.

This is the expected outcome — every one of these functions does its work through SPI inside the
caller's transaction — but it is worth having proved, because `create_sparql_view` reaches into a
second extension and that is exactly where an internal commit would have hidden.

---

## d. What does `_pg_ripple.shacl_shapes.shape_json` contain — is Turtle recoverable?

**No.** It is a parsed, normalised, lossy AST. WORKFLOW.md §4 is right, and the loss is worse
than "formatting is gone": constraints that change the *validation surface* are dropped silently.

```sql
SELECT pg_ripple.load_shacl($ttl$
# A comment that cannot survive a parse.
@prefix sh:  <http://www.w3.org/ns/shacl#> .
@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
@prefix ex:  <https://example.org/> .

ex:RichShape a sh:NodeShape ;
    sh:targetClass ex:Person ;
    sh:closed true ;
    sh:severity sh:Warning ;
    sh:property [
        sh:path ex:name ; sh:name "name" ; sh:description "The person's name." ;
        sh:minCount 1 ; sh:maxCount 1 ; sh:datatype xsd:string ;
        sh:minLength 2 ; sh:maxLength 64 ; sh:pattern "^[A-Z]" ; sh:order 1 ;
    ] ;
    sh:property [ sh:path ex:age   ; sh:datatype xsd:integer ; sh:minInclusive 0 ; sh:maxInclusive 150 ] ;
    sh:property [ sh:path ex:knows ; sh:class ex:Person ; sh:nodeKind sh:IRI ] .
$ttl$);

SELECT jsonb_pretty(shape_json) FROM _pg_ripple.shacl_shapes
WHERE  shape_iri = 'https://example.org/RichShape';
```

```json
{
    "target": { "Class": "https://example.org/Person" },
    "shape_iri": "https://example.org/RichShape",
    "properties": [
        {
            "path_iri": "https://example.org/name",
            "shape_iri": "name",
            "constraints": [
                { "MinCount": 1 },
                { "MaxCount": 1 },
                { "Datatype": "http://www.w3.org/2001/XMLSchema#string" },
                { "MinLength": 2 },
                { "MaxLength": 64 },
                { "Pattern": ["^[A-Z]", null] }
            ]
        },
        {
            "path_iri": "https://example.org/age",
            "shape_iri": "_blank_20eef87e",
            "constraints": [
                { "Datatype": "http://www.w3.org/2001/XMLSchema#integer" },
                { "MinInclusive": "0" },
                { "MaxInclusive": "150" }
            ]
        },
        {
            "path_iri": "https://example.org/knows",
            "shape_iri": "_blank_20ef0221",
            "constraints": [
                { "Class": "https://example.org/Person" },
                { "NodeKind": "http://www.w3.org/ns/shacl#IRI" }
            ]
        }
    ],
    "constraints": [ { "Closed": { "ignored_properties": [] } } ],
    "deactivated": false
}
```

Kept: the shape IRI, `sh:targetClass`, one entry per `sh:property` with its `sh:path` and the
constraints the validator models, node-level constraints (`sh:closed`), and `deactivated`.

Dropped:

| Lost | Why it matters |
|---|---|
| `sh:severity sh:Warning` | **Silently gone.** A regenerated shape would report Violation where the source said Warning. |
| `sh:name`, `sh:description` | `sh:name` is not kept as a constraint — it is repurposed as the property's internal `shape_iri` label (`"name"` above, versus `_blank_<hash>` where absent). Non-recoverable and non-round-trippable. |
| `sh:order` | Property ordering in reports. |
| Prefix declarations | Every IRI is expanded; `ex:Person` cannot be re-abbreviated. |
| Blank node identity | Regenerated as `_blank_<hash>` from content, so a re-parse of regenerated Turtle yields different labels. |
| Comments, whitespace, statement order | Ordinary parse loss. |
| Document grouping | See D3 below. |

**D3 — a multi-shape document is shredded.** Two shapes in one Turtle document become two
independent rows with no grouping key:

```sql
SELECT pg_ripple.load_shacl($ttl$
@prefix sh: <http://www.w3.org/ns/shacl#> .
@prefix ex: <https://example.org/> .
ex:AShape a sh:NodeShape ; sh:targetClass ex:A ; sh:property [ sh:path ex:x ; sh:minCount 1 ] .
ex:BShape a sh:NodeShape ; sh:targetClass ex:B ; sh:property [ sh:path ex:y ; sh:minCount 1 ] .
$ttl$) AS shapes_loaded;
```

```
 shapes_loaded
---------------
             2

         shape_iri
----------------------------
 https://example.org/AShape
 https://example.org/BShape
```

`shacl_shapes` is `(shape_iri, shape_json, active, created_at, updated_at)` — no source column,
no document id. So the dumper cannot even reconstitute which definition file a shape came from.

**D2 — `export_turtle()` is not a back door.** `load_shacl` does not put the shape triples into
the RDF store, so exporting the graph does not export the shapes:

```sql
SELECT length(pg_ripple.export_turtle()) AS ttl_len,
       (SELECT count(*) FROM _pg_ripple.dictionary WHERE value LIKE '%shacl#%') AS shacl_terms_interned;
```

```
 ttl_len | shacl_terms_interned
---------+----------------------
     599 |                    0
```

599 bytes is the two test triples loaded in §c; zero SHACL terms were ever interned. And there is
no `export_shacl` in the extension —

```sql
SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'pg_ripple' AND (p.proname LIKE '%export%' OR p.proname LIKE '%sha%');
```

returns `export_turtle`, `export_jsonld`, `export_nquads`, … and `load_shacl`, `drop_shape`,
`list_shapes`, `load_shape_bundle` — no shape exporter of any kind.

**Verdict:** WORKFLOW.md §4's plan stands unchanged. Shapes are dumped as a comment plus a
pointer to `rake pg_ripple:shapes:load`, and the comment can honestly quote only the shape IRI
and its target — `list_shapes()` returns `(shape_iri, active)`, and the property count must come
from `jsonb_array_length(shape_json->'properties')`.

---

## e. Published container image tag for CI

**`ghcr.io/trickle-labs/pg-ripple:0.128.0`.**

```sh
$ docker image inspect ghcr.io/trickle-labs/pg-ripple:latest \
    --format '{{index .Config.Labels "org.opencontainers.image.version"}}'
0.128.0

$ for t in 0.128.0 0.128 v0.128.0 18 latest; do
    printf '%-10s ' "$t"
    docker manifest inspect ghcr.io/trickle-labs/pg-ripple:$t >/dev/null 2>&1 && echo EXISTS || echo absent
  done
0.128.0    EXISTS
0.128      EXISTS
v0.128.0   absent
18         absent
latest     EXISTS
```

Three tag forms are published: `latest`, the exact version `0.128.0`, and the minor series
`0.128`. There is no `v`-prefixed and no PostgreSQL-major tag. Pin CI to `0.128.0` — `0.128` still
moves under the workflow and `latest` moves further.

The image sets the standard OCI labels, so a CI step can assert the extension version it got
without connecting:

```
org.opencontainers.image.version=0.128.0
org.opencontainers.image.revision=d08c80de17e34e16079a59c4c44e2a54dc2283a9
org.opencontainers.image.source=https://github.com/trickle-labs/pg-ripple
org.opencontainers.image.licenses=Apache-2.0
```

Container startup is fast — `pg_isready` succeeded about a second after the entrypoint finished
initdb — so the usual GitHub Actions service `--health-cmd pg_isready` is sufficient.

---

## Additional findings the probe forced out

These were not questions in §7, but each invalidates something later phases would have built.

### 1. `create_sparql_view` requires pg_trickle, which the image ships but does not install

```sql
SELECT pg_ripple.create_sparql_view('people', 'PREFIX ex: <https://example.org/> SELECT ?s ?n WHERE { ?s ex:name ?n }');
-- ERROR:  pg_trickle is not installed — SPARQL views require pg_trickle;
-- hint: Install pg_trickle: https://github.com/trickle-labs/pg-trickle
--       — then run: CREATE EXTENSION pg_trickle

SELECT name, default_version, installed_version FROM pg_available_extensions
WHERE name IN ('pg_ripple','pg_trickle','vector');
```

```
    name    | default_version | installed_version
------------+-----------------+-------------------
 vector     | 0.8.2           |
 pg_trickle | 0.68.0          |
 pg_ripple  | 0.128.0         | 0.128.0
```

pg_trickle 0.68.0 is present in the image but is not installed by `CREATE EXTENSION pg_ripple`,
and `CREATE EXTENSION pg_ripple CASCADE` does not pull it in — it is a soft dependency. So
`pg_ripple_enabled?` is not a sufficient guard for the SPARQL-view statements; they need their
own `pg_trickle_enabled?` check, and the generator's `USAGE` must tell people to install it.

### 2. `create_sparql_view` is broken for any name that does not already exist (upstream bug)

`views/sparql.rs` unconditionally calls `pgtrickle.drop_stream_table` before creating, to make
repeat calls idempotent (upstream issue #83):

```rust
// IDEMPOTENT-02 (issue #83): drop any pre-existing stream table so that a
// repeated call replaces the view cleanly instead of erroring.
let _ = Spi::run(&format!(
    "SELECT pgtrickle.drop_stream_table(name => '{escaped_stream_table}')"
));
```

pg_trickle 0.68.0 raises a Postgres `ERROR` when the table is absent, which aborts the
transaction; `let _ =` cannot swallow it. So the *first* creation of any view always fails:

```sql
SELECT pg_ripple.create_sparql_view('people', 'PREFIX ex: <https://example.org/> SELECT ?s ?n WHERE { ?s ex:name ?n }');
-- ERROR:  stream table not found: pg_ripple.people
-- HINT:  Use pgtrickle.pgt_status() to list existing stream tables.
```

Repeating the call does not help — it fails identically every time. `pgtrickle` has a
`drop_stream_table(name text, cascade boolean DEFAULT false)` with no `if_exists`, and a
`create_stream_table_if_not_exists`, so the upstream fix is a one-line change to use the latter.

Workaround, proven to work: create the stream table under the view's name first, then call
`create_sparql_view`, which drops and rebuilds it correctly.

```sql
SELECT pgtrickle.create_stream_table(name => 'pg_ripple.people',
         query => 'SELECT id AS s FROM _pg_ripple.dictionary', schedule => '1s');
SELECT pg_ripple.create_sparql_view('people',
         'PREFIX ex: <https://example.org/> SELECT ?s ?n WHERE { ?s ex:name ?n }') AS var_count;
SELECT name, sparql, schedule, decode, stream_table, variables FROM _pg_ripple.sparql_views;
```

```
 var_count
-----------
         2

  name  |                        sparql                        | schedule | decode |   stream_table   | variables
--------+------------------------------------------------------+----------+--------+------------------+------------
 people | PREFIX ex: <https://example.org/> SELECT ?s ?n WHERE… | 1s       | f      | pg_ripple.people | ["s", "n"]
```

The placeholder query must reference a real table — pg_trickle rejects `SELECT 1::bigint AS s`
with *"Defining query references no tables"* — and the SPARQL query must reference a predicate
that exists in the store, or compilation produces table-less SQL and fails the same way. That
second constraint is significant for the feature specs: **`create_ripple_sparql_view` cannot be
tested against an empty database.** The spec fixture has to load triples before creating a view.

Whether the gem should ship this workaround is a phase-3 decision. It is three lines and it is
transactional, but it hard-codes a pg_trickle internal. Recommendation: file the upstream issue,
and in the meantime raise a clear error from `create_ripple_sparql_view` pointing at it rather
than silently papering over an extension bug.

`_pg_ripple.sparql_views` keeps `sparql` **verbatim** — the exact string passed in, prefixes and
all — so views round-trip as WORKFLOW.md §4 promised, provided `schedule` and `decode` are dumped
alongside `name` and `sparql`.

### 3. Graphs do not round-trip — `create_graph` is not a schema operation

This is the finding with the largest blast radius. `create_graph` does not create anything:

```rust
// src/storage/ops/scan.rs
/// Encode a named graph IRI and return its dictionary id.
/// This is idempotent — calling it again returns the same id.
pub fn create_graph(graph_iri: &str) -> i64 {
    dictionary::encode(strip_angle_brackets(graph_iri), dictionary::KIND_IRI)
}
```

It interns the IRI in the term dictionary and returns its id. And `list_graphs` does not read a
catalog — it derives graph IRIs from the distinct `g` column values across every VP table:

```rust
/// List all named graph IRIs (excludes the default graph 0).
pub fn list_graphs() -> Vec<String> {
    // Collect distinct g values > 0 from all VP tables and vp_rare, decode them.
```

`_pg_ripple.named_graphs` exists but is written only by the views API, and stayed empty
throughout. So **a graph with no triples in it is invisible**:

```sql
SELECT pg_ripple.create_graph('https://example.org/keepme');   -- returns 10
SELECT * FROM pg_ripple.list_graphs();
--  graph_iri
-- -----------
-- (0 rows)

SELECT pg_ripple.insert_triple('<https://example.org/alice>','<https://example.org/name>','"Alice"',
                               'https://example.org/keepme');
SELECT * FROM pg_ripple.list_graphs();
--           graph_iri
-- ------------------------------
--  <https://example.org/keepme>
```

Consequences:

- A migration's `create_ripple_graph` leaves **nothing** for `db:schema:dump` to find. Graphs
  cannot appear in `schema.rb` at all, and a graph that *does* appear is an artefact of seed data
  rather than of schema.
- Conversely a graph nobody declared shows up the moment seed triples land in it, so dumping
  `list_graphs()` would write data-dependent noise into `schema.rb` and make the dump
  non-deterministic across environments.
- `drop_graph` deletes triples (it returned `1` after one triple). It is a **data** operation, and
  reverting `create_ripple_graph` by calling it would destroy rows.
- `list_graphs()` returns IRIs wrapped in angle brackets (`<https://…>`) while `create_graph`
  accepts either form and strips them. Any comparison must normalise.

### 4. `pg_ripple_version` cannot come from `_pg_ripple.schema_version`

WORKFLOW.md §5 proposes
`SELECT version FROM _pg_ripple.schema_version ORDER BY installed_at DESC LIMIT 1`. That table is
an internal *migration ledger* with one row per catalog upgrade step, and it stops well short of
the extension version:

```sql
SELECT * FROM _pg_ripple.schema_version ORDER BY installed_at DESC LIMIT 3;
```

```
 version |         installed_at          | upgraded_from
---------+-------------------------------+---------------
 0.98.0  | 2026-08-06 13:29:58.431408+00 | 0.97.0
 0.97.0  | 2026-08-06 13:29:58.428575+00 | 0.96.0
 0.78.0  | 2026-08-06 13:29:58.425986+00 | 0.77.0
```

33 rows, top row `0.98.0`, while the installed extension is `0.128.0`. Worse, the rows are
inserted within milliseconds of each other during `CREATE EXTENSION`, so `ORDER BY installed_at`
is a tie-break on a timestamp and the "latest" row is not stable — note `0.78.0` sorting above
`0.97.0`'s predecessor here.

Use `pg_extension` instead:

```sql
SELECT extversion FROM pg_extension WHERE extname = 'pg_ripple';
--  extversion
-- ------------
--  0.128.0
```

which is also exactly what the image's `org.opencontainers.image.version` label reports, so
`rake pg_ripple:status` and CI agree.

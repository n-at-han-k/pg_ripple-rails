# Probe: CONSTRUCT + JSON-LD framing (phase 4)

All output below is verbatim from **pg_ripple 0.128.0** in a container I created for this
phase (`ripple-jsonld-p4`, `ghcr.io/trickle-labs/pg-ripple:0.128.0`, `--rm`, no volume, no
network), database `ripplespec`, extension `0.128.0`, PostgreSQL 18. The container was
removed before this phase finished.

This file records **measured behaviour**. Where it disagrees with README "Preloading" or with
the upstream doc comments, this file wins, on the same footing as `docs/probe-results.md`.

## Verdict up front

Framing **does** nest — but not with the frame README publishes, and not on the terms README
assumes. Six things must all be true before a nested document comes back, and README's
three-line example gets **four** of them wrong. The corrected recipe is in
[§ The recipe that works](#the-recipe-that-works). README "Preloading" needs its example
rewritten; it does **not** need redesigning around plain CONSTRUCT.

Separately, and independent of framing: at a realistic page size framing is **not** the fastest
option. Two batched association queries beat the framed CONSTRUCT by ~1.6× and beat lazy N+1
by ~6.6×. See [§ g](#g-rough-cost).

---

## The fixture

Six people, three managed by one manager, one managed by another, one organisation, one
person with no employer. 22 triples. Loaded with `pg_ripple.insert_triple(s, p, o)`.

```
ex:alice a foaf:Person ; foaf:name "Alice" ; ex:role "manager" ;
         ex:manages ex:bob, ex:carol, ex:dave ; ex:worksAt ex:acme .
ex:erin  a foaf:Person ; foaf:name "Erin"  ; ex:role "manager" ;
         ex:manages ex:frank .                        # no ex:worksAt -> the unmatched OPTIONAL
ex:bob   a foaf:Person ; foaf:name "Bob"   ; ex:role "engineer" .
ex:carol a foaf:Person ; foaf:name "Carol" .
ex:dave  a foaf:Person ; foaf:name "Dave" .
ex:frank a foaf:Person ; foaf:name "Frank" .
ex:acme  a ex:Organization ; foaf:name "Acme" .
```

For § g a second fixture of 200 managers × (name, role, employer, 3 named reports) + 10 orgs
was added, bringing the database to 2032 triples. Nothing here is large enough to need
`temp_file_limit`, so no `ALTER SYSTEM` was issued.

---

## a. Real signatures

From `pg_proc`, not from the docs:

```sql
SELECT p.proname||'('||pg_get_function_arguments(p.oid)||') -> '||pg_get_function_result(p.oid)
FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'pg_ripple' AND (p.proname LIKE '%jsonld%' OR p.proname LIKE '%frame%')
ORDER  BY 1;
```
```
apply_frame_redaction(frame jsonb, payload jsonb) -> jsonb
export_jsonld(graph text DEFAULT NULL::text) -> jsonb
export_jsonld_framed(frame jsonb, graph text DEFAULT NULL::text, embed text DEFAULT '@once'::text, explicit boolean DEFAULT false, ordered boolean DEFAULT false) -> jsonb
export_jsonld_framed_stream(frame jsonb, graph text DEFAULT NULL::text) -> TABLE(line text)
export_jsonld_node(frame jsonb, subject_id bigint, strip text[] DEFAULT ARRAY['@type'::text, '@id'::text]) -> jsonb
export_jsonld_stream(graph text DEFAULT NULL::text) -> TABLE(line text)
ingest_jsonld(document jsonb, graph_iri text DEFAULT NULL::text, mode text DEFAULT 'append'::text, source_timestamp timestamp without time zone DEFAULT NULL::timestamp without time zone) -> bigint
jsonld_frame(input jsonb, frame jsonb, embed text DEFAULT '@once'::text, explicit boolean DEFAULT false, ordered boolean DEFAULT false) -> jsonb
jsonld_frame_to_sparql(frame jsonb, graph text DEFAULT NULL::text) -> text
load_jsonld(document jsonb, graph_uri text DEFAULT NULL::text) -> bigint
sparql_construct_jsonld(query text) -> jsonb
sparql_cursor_jsonld(query text) -> TABLE(chunk text)
sparql_describe_jsonld(query text, strategy text DEFAULT 'cbd'::text) -> jsonb
triple_to_jsonld(s bigint, p bigint, o bigint) -> jsonb
triples_to_jsonld(subject bigint) -> jsonb
```

### The first README error: `sparql_construct_jsonld` takes no frame

`sparql_construct_jsonld(query text) -> jsonb`. **One argument.** README says
"`graph_includes` compiles to one `CONSTRUCT` shaped by a JSON-LD frame, via
`pg_ripple.sparql_construct_jsonld()`" and then prints a frame. There is nowhere to put it.
`sparql_construct_jsonld` returns **JSON-LD expanded form**, unframed
(`src/sparql_api.rs:103` -> `src/export/mod.rs:531 triples_to_jsonld`).

There are exactly two framing entry points, and they are different shapes of tool:

| | input | who writes the CONSTRUCT | scope |
|---|---|---|---|
| `jsonld_frame(input, frame, …)` | an already-expanded JSON-LD array | **you** | whatever your query returned |
| `export_jsonld_framed(frame, graph, …)` | nothing | the extension, from the frame | **the whole graph** — no page, no filter |

`jsonld_frame_to_sparql(frame, graph)` is the inspection tool: it returns the CONSTRUCT
`export_jsonld_framed` would run, without running it.

**Consequence for `graph_includes`:** `export_jsonld_framed` is unusable for preloading. It has
no way to say "these 20 subjects". Its only restriction is `graph`, and named graphs are not a
schema object here. Preloading must be `sparql_construct_jsonld(<query with VALUES>)` piped
into `jsonld_frame(...)` — two extension calls, still one round trip if composed in SQL.

`export_jsonld_node(frame, subject_id, strip)` frames exactly one subject by **dictionary id**
(not IRI), so it is a per-record tool, i.e. the N+1 it was supposed to replace.

`@embed` accepts only three values; a fourth raises rather than being ignored:

```
ERROR:  PT711: unrecognised @embed value: "@link"; expected @once, @always, or @never
```

---

## b. README "Preloading", exactly as published

### b.1 It does not parse

```sql
SELECT jsonb_pretty(pg_ripple.sparql_construct_jsonld($q$
CONSTRUCT { ?s ex:manages ?report ; ex:worksAt ?org }
WHERE     { ?s a foaf:Person ; ex:role "manager" .
            OPTIONAL { ?s ex:manages ?report }
            OPTIONAL { ?s ex:worksAt ?org } }
$q$));
```
```
ERROR:  SPARQL parse error: error at 2:26: expected one of Prefix not found, ['%'], …
```

`ex:` and `foaf:` were **registered** first:

```
 prefix |         expansion
--------+----------------------------
 ex     | https://example.org/
 foaf   | http://xmlns.com/foaf/0.1/
```

Registered prefixes are not consulted by the SPARQL parser — not in a CONSTRUCT template, not
in its WHERE, and not in a plain SELECT:

```
SELECT-registered-prefix  -> ERROR: SPARQL parse error … Prefix not found
SELECT-explicit-prefix    -> 4 rows
```

This corroborates `spec-corrections.md` §"The prefix registry lives in the process, not the
database" (and its `PREFIX`-lines note) from a third direction: the registry is not a SPARQL
namespace at all. **Every query this gem emits must carry its own `PREFIX` lines.**

### b.2 With `PREFIX` lines added, the CONSTRUCT runs — and comes back flat

```sql
SELECT jsonb_pretty(pg_ripple.sparql_construct_jsonld($q$
PREFIX ex:   <https://example.org/>
PREFIX foaf: <http://xmlns.com/foaf/0.1/>
CONSTRUCT { ?s ex:manages ?report ; ex:worksAt ?org }
WHERE     { ?s a foaf:Person ; ex:role "manager" .
            OPTIONAL { ?s ex:manages ?report }
            OPTIONAL { ?s ex:worksAt ?org } }
$q$));
```
```json
[
    {
        "@id": "https://example.org/alice",
        "https://example.org/manages": [
            { "@id": "https://example.org/bob" },
            { "@id": "https://example.org/carol" },
            { "@id": "https://example.org/dave" }
        ],
        "https://example.org/worksAt": [
            { "@id": "https://example.org/acme" },
            { "@id": "https://example.org/acme" },
            { "@id": "https://example.org/acme" }
        ]
    },
    {
        "@id": "https://example.org/erin",
        "https://example.org/manages": [
            { "@id": "https://example.org/frank" }
        ]
    }
]
```

Three separate facts in that one blob:

1. **Expanded form, no `@context`, no `@graph`** — a bare JSON array of node objects.
2. **`ex:acme` three times.** The CONSTRUCT emits one triple *per solution*, and
   `triples_to_jsonld` pushes every row without de-duplicating
   (`src/export/mod.rs:531-560` — plain `.push(o_val)`). Two sibling `OPTIONAL`s produce a
   Cartesian product: 3 reports × 1 employer = 3 solutions, so the employer is repeated 3×.
   **CONSTRUCT here does not have RDF set semantics.** Any consumer must de-duplicate by
   `@id`.
3. **`erin` has no `worksAt` key at all** — see § d.

### b.3 README's exact frame returns nothing

```sql
SELECT jsonb_pretty(pg_ripple.jsonld_frame(
  pg_ripple.sparql_construct_jsonld(<the query above>),
  '{"@type": "foaf:Person", "ex:manages": {}, "ex:worksAt": {}}'::jsonb));
```
```json
{
    "@graph": [
    ]
}
```

Empty, and **silently** so — no error, no warning. Three independent reasons, each sufficient:

* the CONSTRUCT template never emits `?s a foaf:Person`, so no node in the input has a type
  for `"@type"` to match;
* `"foaf:Person"` is a compact IRI and nothing expands it (§ f);
* `"ex:manages": {}` would not have nested anything even if the roots had matched (§ b.4).

### b.4 An empty `{}` slot never nests — that is the crux

With the type triple added to the CONSTRUCT and the frame's IRIs written out in full, roots
match, and the result is still flat:

```sql
pg_ripple.jsonld_frame(<construct incl. `?s a foaf:Person`>,
  '{"@type": "http://xmlns.com/foaf/0.1/Person",
    "https://example.org/manages": {},
    "https://example.org/worksAt": {}}'::jsonb)
```
```json
{
    "@graph": [
        {
            "@id": "https://example.org/alice",
            "https://example.org/manages": [
                { "@id": "https://example.org/bob" },
                { "@id": "https://example.org/carol" },
                { "@id": "https://example.org/dave" }
            ],
            …
```

`foaf:name` for bob/carol/dave was in the input document and was **dropped**. Passing
`embed => '@always'` changes nothing.

Now the same input with a **non-empty sub-frame**:

```sql
pg_ripple.jsonld_frame(<same input>,
  '{"@type": "http://xmlns.com/foaf/0.1/Person",
    "https://example.org/manages": {"http://xmlns.com/foaf/0.1/name": {}}}'::jsonb)
```
```json
{
    "@graph": [
        {
            "@id": "https://example.org/alice",
            "https://example.org/manages": [
                {
                    "@id": "https://example.org/bob",
                    "http://xmlns.com/foaf/0.1/name": [ { "@value": "Bob" } ]
                },
                {
                    "@id": "https://example.org/carol",
                    "http://xmlns.com/foaf/0.1/name": [ { "@value": "Carol" } ]
                },
                {
                    "@id": "https://example.org/dave",
                    "http://xmlns.com/foaf/0.1/name": [ { "@value": "Dave" } ]
                }
            ],
            "https://example.org/worksAt": [
                { "@id": "https://example.org/acme" },
                { "@id": "https://example.org/acme" },
                { "@id": "https://example.org/acme" }
            ],
            …
```

`manages` nested; `worksAt`, still `{}` in the frame, did not. **Framing nests.**

The rule, and it is in the source: `src/framing/embedder.rs:276` guards the recursion with
`&& !child_obj.is_empty()`. **The frame is a projection list, not a matcher** — every child
property you want must be named in the sub-frame. This deviates from W3C JSON-LD Framing,
where `{}` with the default `@embed: @once` embeds the node with all its properties.

### b.5 `@once` drops properties from shared children — non-deterministically

Twenty roots on the page fixture, ten organisations, each employer shared by two roots:

```
    e    | roots | roots_with_named_org
---------+-------+----------------------
 @always |    20 |                   20
 @never  |    20 |                    0
 @once   |    20 |                   10
```

Under the default `@once`, exactly one of the two roots sharing an employer gets the embedded
copy; the other gets a bare `{"@id": …}` for the same node. Which one depends on hash-map
iteration order. A preloader **must** pass `embed => '@always'`.

### b.6 `@graph` is not "one entry per root", and is unordered

`export_jsonld_framed` with `{"@type": foaf:Person, worksAt: {name:{}}}` on the small fixture:

```json
{
    "@graph": [
        { "@id": "https://example.org/dave",  "…#type": [ { "@id": "http://xmlns.com/foaf/0.1/Person" } ] },
        { "@id": "https://example.org/frank", "…#type": [ … ] },
        { "@id": "https://example.org/carol", "…#type": [ … ] },
        { "@id": "https://example.org/erin",  "…#type": [ … ] },
        { "@id": "https://example.org/alice",
          "https://example.org/worksAt": [
              { "@id": "https://example.org/acme",
                "http://xmlns.com/foaf/0.1/name": [ { "@value": "Acme" } ] } ],
          "…#type": [ … ] },
        { "@id": "https://example.org/bob",   "…#type": [ … ] }
    ]
}
```

* Order is hash order (`dave, frank, carol, erin, alice, bob`), not insertion or IRI order.
  There is an `ordered` boolean parameter; the hydrator should not rely on order either way.
* Every node matching the frame's `@type` is a root, including nodes that are somebody else's
  child. In the `@once` run of § f, `ex:frank` appears **at top level carrying `foaf:name`**
  while `ex:erin`'s nested `ex:frank` is the bare reference — the embedded copy went to
  whichever position the embedder reached first.

**The hydrator must key `@graph` by `@id` and treat it as a node pool, not a result list.**

---

## The recipe that works

Six things, all required:

1. `PREFIX` lines in the query — registered prefixes are invisible (§ b.1).
2. The CONSTRUCT template must emit the discriminator the frame matches on (`?s a foaf:Person`).
3. Restrict the page in the **query**, with `VALUES ?s { … }`; `export_jsonld_framed` cannot
   be paged (§ a).
4. Fully expanded IRIs in the frame — never compact ones (§ f).
5. A non-empty sub-frame for every association you want nested (§ b.4).
6. `embed => '@always'` (§ b.5).

```sql
SELECT pg_ripple.jsonld_frame(
  pg_ripple.sparql_construct_jsonld($q$
    CONSTRUCT { ?s <…#type> <http://xmlns.com/foaf/0.1/Person> .
                ?s <https://example.org/manages> ?report . ?report <http://xmlns.com/foaf/0.1/name> ?rn .
                ?s <https://example.org/worksAt> ?org  . ?org  <http://xmlns.com/foaf/0.1/name> ?on }
    WHERE     { VALUES ?s { <https://example.org/p0> … }
                ?s <…#type> <http://xmlns.com/foaf/0.1/Person> .
                OPTIONAL { ?s <https://example.org/manages> ?report . ?report <http://xmlns.com/foaf/0.1/name> ?rn }
                OPTIONAL { ?s <https://example.org/worksAt> ?org  . ?org  <http://xmlns.com/foaf/0.1/name> ?on } }
  $q$),
  '{"@type": "http://xmlns.com/foaf/0.1/Person",
    "https://example.org/manages":  {"http://xmlns.com/foaf/0.1/name": {}},
    "https://example.org/worksAt":  {"http://xmlns.com/foaf/0.1/name": {}}}'::jsonb,
  '@always');
```

and the hydrator still has to de-duplicate by `@id` (§ b.2) and index `@graph` by `@id`
(§ b.6). Note the query text is built by the gem, not by a user — but the page IRIs still go
in as bound values wherever the query is assembled, never concatenated from user input.

---

## c. Many values vs one value — the classic trap is **absent**

Alice manages three, Erin manages exactly one:

```json
"https://example.org/manages": [ {"@id": "…/bob"}, {"@id": "…/carol"}, {"@id": "…/dave"} ]
```
```json
"https://example.org/manages": [ {"@id": "…/frank"} ]
```

A single value is a **one-element array**, not a bare object. Same for a single literal:
`"http://xmlns.com/foaf/0.1/name": [ { "@value": "Frank" } ]`.

This holds at every level, in `sparql_construct_jsonld`, in `jsonld_frame` and in
`export_jsonld_framed`, with and without `@context`. It is unconditional in the source:
`src/framing/embedder.rs:296` writes `output.insert(pred_iri.clone(), Value::Array(output_values))`,
and `triples_to_jsonld` always builds a `Vec`.

**Finding: values are always arrays.** The output is never compacted in the JSON-LD sense
(§ f), which is precisely what normally introduces the one-vs-many inconsistency. The hydrator
does not need an `Array(value)` wrapper — but it should keep one anyway as a cheap guard, and
it **does** need to de-duplicate: cardinality is not trustworthy (§ b.2 gives `worksAt` three
identical entries for a single-valued property, and the page fixture reproduces it: `p0` has
3 `worksAt` entries for 1 employer).

Literal shapes, for the hydrator's value coercion:

```json
"https://example.org/age":      [ { "@type": "http://www.w3.org/2001/XMLSchema#integer", "@value": "42" } ],
"https://example.org/nickname": [ { "@value": "Ali", "@language": "en" } ]
```

`@value` is **always a JSON string** — an `xsd:integer` does not come back as a JSON number.
Datatype and language arrive as sibling keys, not inside the string. Contrast the settled
lateral-join rule, where a literal's datatype or language is *inside* the term string; in
JSON-LD it is split out for you.

---

## d. An OPTIONAL that did not match

**The key is absent.** Not `null`, not `[]`.

`ex:erin` has no `ex:worksAt`. In every run above — raw `sparql_construct_jsonld`,
`jsonld_frame`, `export_jsonld_framed` — erin's node object simply has no
`"https://example.org/worksAt"` key.

The hydrator must therefore distinguish *absent* from *empty* by convention, not by the
payload: a missing key means "the OPTIONAL did not match", which for a `graph_has_many` is an
empty collection and for a `graph_has_one` is `nil`. There is no way to tell that apart from
"the frame never asked for this property" — so the hydrator must drive from the *requested*
association list, marking every requested association loaded and defaulting to empty, rather
than from the keys present in the payload. Doing it the other way round leaves associations
silently unloaded and re-triggers N+1.

`explicit => true` prunes non-framed properties and collapses roots with no framed property to
a bare `{"@id": …}`; it does not turn absence into null:

```json
{ "@graph": [ { "@id": "https://example.org/carol" },
              { "@id": "https://example.org/alice",
                "https://example.org/worksAt": [ { "@id": "https://example.org/acme",
                    "http://xmlns.com/foaf/0.1/name": [ { "@value": "Acme" } ] } ] },
              { "@id": "https://example.org/dave" }, … ] }
```

---

## e. IRIs: bare, or angle-bracketed?

**Bare.** No angle brackets anywhere in JSON-LD output, at any nesting level, in `@id` or in
an object position. Side by side, same subject, same database:

```
 lateral term string | {"iri": "<https://example.org/alice>"}
 jsonld @id          | [{"@id": "https://example.org/alice", "https://example.org/manages": [{"@id": "https://example.org/bob"}]}]
```

`triples_to_jsonld` strips the brackets explicitly (`src/export/mod.rs:544-552`).

**The hydrator must NOT btrim the JSON-LD side.** The settled `btrim(r.result ->> 'iri', '<>')`
belongs to the lateral `sparql()` path only. If the two paths are ever joined, they must be
normalised on the lateral side.

### The one exception, and it is a trap

If the frame carries a prefix `@context`, `@id` and `@type` come back **compacted to CURIEs**:

```json
{ "@graph": [ { "@id": "ex:alice",
                "https://example.org/manages": [ { "@id": "ex:bob", … } ],
                "http://www.w3.org/1999/02/22-rdf-syntax-ns#type": [ { "@id": "foaf:Person" } ] } ],
  "@context": { "ex": "https://example.org/", "foaf": "http://xmlns.com/foaf/0.1/" } }
```

Property **keys** are never compacted (`https://example.org/manages` stayed full even with
`ex` in scope) — compaction touches only `@id` and `@type` string values
(`src/framing/compactor.rs:126-145`). So a frame with a `@context` yields a document whose
`@id` no longer matches the `iri` column and whose keys are still full IRIs: the worst of both.

**Rule for the gem: never put a prefix `@context` in a frame.** Without one, every IRI in the
output is a bare full IRI and joins directly on `iri`.

---

## f. `@context` and compact IRIs

* **Does `@context` come back?** Yes, verbatim, as given in the frame. It is copied to the
  output document, not derived. Omit it from the frame and the output has none.
* **Can a compact IRI in the frame be used without registering a prefix first?** **No — and it
  fails silently.** Registering does not help either: nothing anywhere expands a CURIE on the
  *input* side, not even against the frame's own `@context`.

`jsonld_frame_to_sparql` proves it. Frame:

```json
{"@context": {"ex":"https://example.org/","foaf":"http://xmlns.com/foaf/0.1/"},
 "@type": "foaf:Person",
 "ex:manages": {"foaf:name": {}},
 "ex:worksAt": {"foaf:name": {}}}
```
```sparql
CONSTRUCT {
    ?_root <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <foaf:Person> .
    ?_root <ex:manages> ?_v0_0 .
    ?_v0_0 <foaf:name> ?_v1_1 .
    ?_root <ex:worksAt> ?_v0_2 .
    ?_v0_2 <foaf:name> ?_v1_3 .
} WHERE {
    ?_root <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <foaf:Person> .
    OPTIONAL { ?_root <ex:manages> ?_v0_0 .
    OPTIONAL { ?_v0_0 <foaf:name> ?_v1_1 . }
    }
    OPTIONAL { ?_root <ex:worksAt> ?_v0_2 .
    OPTIONAL { ?_v0_2 <foaf:name> ?_v1_3 . }
    }
}
```

`<foaf:Person>`, `<ex:manages>` — the CURIE is wrapped in angle brackets and used as an
absolute IRI. It parses, it runs, it matches nothing:

```json
{ "@graph": [ ], "@context": { "ex": "https://example.org/", "foaf": "http://xmlns.com/foaf/0.1/" } }
```

Same frame with expanded IRIs generates the correct CONSTRUCT and returns data.

**So `@context` handling is asymmetric: applied on output, ignored on input.** For the gem that
means a frame is built from `RDF::Vocabulary` terms resolved to full IRIs in Ruby — the frame
is never a place a user's prefix string is trusted — and `@context` is left out entirely.

Also visible above: the frame's own OPTIONAL nesting means `jsonld_frame_to_sparql` produces
*nested* OPTIONALs (`OPTIONAL { … OPTIONAL { … } }`), so a child's sub-property is optional
within its parent's optional. That is the right shape; it is worth copying in the hand-written
CONSTRUCT rather than flattening.

---

## g. Rough cost

Page = 20 subjects (`p0…p19`), each with 3 named reports and 1 named employer; 2032 triples in
the database. Timed inside PostgreSQL with `clock_timestamp()` around the whole call, 15
iterations on one warm backend, so no client round-trip is included and the plan cache is warm
after the first.

| | what | first | median | min |
|---|---|---:|---:|---:|
| **A** | framed CONSTRUCT: `sparql_construct_jsonld(VALUES-restricted query)` + `jsonld_frame` | 30.7 ms | **3.9 ms** | 3.8 ms |
| **B** | 2 batched association queries: one `sparql()` per association, `VALUES ?s { …20… }` | 4.4 ms | **2.4 ms** | 2.4 ms |
| **C** | lazy N+1: 40 `sparql()` calls (20 subjects × 2 associations) | 33.6 ms | **15.8 ms** | 15.8 ms |
| **D** | `export_jsonld_framed` over the whole graph (what README's API implies) | 15.7 ms | **13.5 ms** | 12.6 ms |

A and B return the same 80 solution rows' worth of data. D returns 206 roots — it cannot be
restricted to the page — for a 155 984-byte payload against A's 15 642.

**Findings:**

* Framing beats lazy N+1 by **4.1×** at this page size. The preloading idea is sound.
* Framing **loses to plain batched association queries by 1.6×**, and B's win grows with the
  frame's depth: A pays for the Cartesian product in the CONSTRUCT (§ b.2), the JSON-LD
  materialisation, and then the embed pass, while B runs one flat query per association with
  no cross-product at all. B also returns lateral-shaped rows the existing hydrator already
  understands, and needs no de-duplication, no `@id` pool, no embed mode.
* A's first call is 8× its median (30.7 ms vs 3.9 ms) — SPARQL plan compilation. Note this is
  the same per-backend plan cache that phase 1 found is poisoned by transaction abort; the
  `PgRipple::PlanCache` rollback hook already covers it, and a `graph_includes` query is
  exactly the "stable constant minted once ever" shape that made that fix necessary.
* D is a non-starter regardless of speed: no paging.

**Recommendation, as a decision for a later phase, not settled here:** implement
`graph_includes` as B — one batched `sparql()` per included association, `VALUES` over the page
IRIs — and keep framing for `to_jsonld` / export, where nesting is the product rather than an
intermediate. It is faster, it reuses the lateral-join term decoding that is already built and
tested, and it avoids every trap in § b through § f. If framing is chosen anyway, the recipe
above is the one that works, and none of its six requirements may be dropped.

---

## Applied (phase 5)

`graph_includes` was built on framing, not on batched association queries — see
[`spec-corrections.md` §18](spec-corrections.md) for the decision and the reason (one round
trip regardless of how many associations are named; the 1.5 ms is a per-page constant). The
six-point recipe above is followed, with two departures that were measured while building it
and that this document did not have:

* **§ b.2's Cartesian product is avoidable.** One `OPTIONAL` over a `UNION` of the branches
  makes the solution count the *sum* of the branches rather than their product, and an
  unbound variable simply omits its triple from the CONSTRUCT template. A subject matching no
  branch still appears carrying the root type.
* **§ b.6 needs a caveat: a one-root result is not wrapped in `@graph`** — it is the bare node
  object. Every measurement in this file used a page of two or more. A page of one is every
  `find`-shaped preload.

Also departing from § 5 of the recipe deliberately: the sub-frames are empty `{}`, because
this consumer wants exactly what § b.4 calls the defect — a bare `{"@id": …}` reference. The
record behind it is loaded from its own table by `iri`; the child's triples would be waste.
And the frame's `@type` is the gem's own `urn:x-pg-ripple:frame-root`, asserted by the
template, so preloading does not depend on a model having declared a `graph type:`.

---

## Summary table

| Question | Answer |
|---|---|
| a | `sparql_construct_jsonld(query)` — **one arg, no frame**. Framing is `jsonld_frame(input, frame, embed, explicit, ordered)` or `export_jsonld_framed(frame, graph, embed, explicit, ordered)`; the latter cannot be paged. `@embed` ∈ {`@once`,`@always`,`@never`}. |
| b | README's example fails to parse (registered prefixes are invisible to SPARQL); with `PREFIX` lines it returns **flat expanded form with duplicate entries**; README's frame then returns an **empty `@graph`, silently**. Framing **does** nest, but only with a non-empty sub-frame per association, expanded IRIs, the type triple in the template, and `@always`. |
| c | **Always an array**, one value or many, at every level, everywhere. No bare-object trap. But cardinality is inflated by the CONSTRUCT's Cartesian product — de-duplicate by `@id`. `@value` is always a JSON string; datatype/language are sibling keys. |
| d | **Key absent.** Never `null`, never `[]`. Drive hydration from the requested association list, not from the payload's keys. |
| e | **Bare, no angle brackets** — do *not* btrim the JSON-LD side. Unless the frame carries a prefix `@context`, in which case `@id`/`@type` come back as CURIEs; so don't put one in. |
| f | `@context` is echoed verbatim and applied to output only. A compact IRI in a frame is **never expanded** — it becomes `<ex:manages>` in the generated CONSTRUCT and matches nothing, with no error. |
| g | Framing 3.9 ms vs lazy N+1 15.8 ms vs **batched association queries 2.4 ms** for 20 subjects. Framing beats N+1 but loses to plain batching. |

---

## Upstream defects observed (not filed)

1. **`jsonld_frame_to_sparql` / `export_jsonld_framed` ignore the frame's own `@context`.**
   A compact IRI is emitted as an absolute IRI (`<ex:manages>`), producing a query that
   matches nothing and returning an empty `@graph` with no diagnostic.
   `src/framing/frame_translator.rs`.
2. **An empty `{}` sub-frame does not embed**, contrary to W3C JSON-LD Framing where `{}`
   under the default `@embed: @once` embeds the matched node. Guard at
   `src/framing/embedder.rs:276` (`&& !child_obj.is_empty()`).
3. **`sparql_construct_jsonld` does not de-duplicate triples.** CONSTRUCT is specified to
   produce an RDF graph (a set); this returns one entry per solution, so sibling `OPTIONAL`s
   multiply single-valued properties. `src/export/mod.rs:531`.
4. **Partial compaction.** `@id`/`@type` are compacted against the `@context` while property
   keys are left as full IRIs (`src/framing/compactor.rs:126-145`), producing a document that
   is neither expanded nor compacted form.

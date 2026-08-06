# Building the `pg_ripple` Rails gem

> **Superseded in scope.** README.md is now the design spec, and it is a far larger gem: an
> ActiveRecord mixin, graph associations that return `ActiveRecord::Relation`, a Datalog
> builder, SHACL generated from ActiveModel validations, and twenty other sections. This
> document plans only the **migration and schema-dumping layer** — README's "Migrations" and
> "Schema dumping" sections — which is built and lives in `lib/`. Treat it as the plan for
> one layer of the spec, not for the gem.
>
> Corrections to the spec found by probing the live extension are in
> [`docs/spec-corrections.md`](docs/spec-corrections.md). Read those before planning the rest.

The plan for turning [pg-ripple](https://github.com/trickle-labs/pg-ripple) — a PostgreSQL 18
RDF triple store, SPARQL engine, SHACL validator and Datalog reasoner — into a Rails gem in the
shape of [`fx`](https://github.com/teoljungberg/fx) and
[`pg_cron-rails`](https://github.com/n-at-han-k/pg_cron-rails).

Read [`docs/reference-gem-structure.md`](docs/reference-gem-structure.md) first — it records
what those two gems do and which of their choices are load-bearing. This document only covers
what is different because the extension is pg_ripple.

An executable version of this plan lives in
[`.claude/workflows/build-pg-ripple-rails.js`](.claude/workflows/build-pg-ripple-rails.js).

---

## 1. What the gem manages

pg_ripple exposes ~200 SQL functions. Almost all of them are *queries* — `sparql()`,
`validate()`, `infer()`, `hybrid_search()` — and a Rails app calls those directly through
`ActiveRecord::Base.connection`. The gem has no business wrapping them.

What belongs in migrations is the small set of objects that are **schema**: created once,
versioned in the repo, expected to exist identically in every environment, and required before
the application's queries work. Five kinds:

> **Signatures below are the probed ones.** `docs/src/reference/sql-functions.md` upstream is
> stale on several — notably `load_rules` argument order and the endpoint functions. See
> [`docs/probe-results.md` §0](docs/probe-results.md#0-signatures-the-docs-get-wrong).

| Object | Create | Drop | Catalog | Definition file |
|---|---|---|---|---|
| Prefix | `register_prefix(prefix, expansion)` | — | `_pg_ripple.prefixes` | — (two scalars) |
| SHACL shape set | `load_shacl(turtle)` | `drop_shape(iri)` | `_pg_ripple.shacl_shapes` | `db/ripple/shapes/<name>_v01.ttl` |
| Datalog rule set | `load_rules(program, name)` | `drop_rules(name)` | `_pg_ripple.rules` | `db/ripple/rules/<name>_v01.dl` |
| SPARQL view | `create_sparql_view(name, query, schedule, decode, immediate)` | `drop_sparql_view(name)` | `_pg_ripple.sparql_views` | `db/ripple/views/<name>_v01.rq` |
| Federation endpoint | `register_endpoint(url, local_view_name, complexity, graph_iri)` | `remove_endpoint(url)` | `_pg_ripple.federation_endpoints` | — (scalars) |

Five kinds, not six. Note that a **federation endpoint is keyed by its URL, not by a name** —
there is no `name` argument anywhere in the endpoint API — and that a **SPARQL view is a
scheduled, incrementally-maintained pg_trickle stream table**, so `schedule` and `decode` are
part of its definition and must round-trip alongside `name` and `sparql`.

Deliberately out of scope for v1, with reasons:

- **Named graphs.** `create_graph(iri)` was the sixth kind until the probe showed it is not a
  schema operation at all: it interns the IRI in the term dictionary and returns its id, creating
  no catalog row. `list_graphs()` derives its answer from the distinct graph column of the VP
  tables, so **a graph holding no triples is invisible**, and a graph holding seed triples appears
  whether or not any migration declared it. Dumping it would write data-dependent noise into
  `schema.rb`. `drop_graph` deletes triples, so it is a data operation and cannot serve as the
  inverse of a create. Graphs are seed-data concerns; see
  [`docs/probe-results.md` §3](docs/probe-results.md#3-graphs-do-not-round-trip--create_graph-is-not-a-schema-operation).
- **Triple data** (`load_turtle`, `insert_triple`). That is seed data, not schema. A
  `db/ripple/seeds` rake task can load it; it must not go in `schema.rb`.
- **Federation credentials.** `set_federation_credential` stores pgcrypto-encrypted tokens.
  Secrets never belong in a migration or a dumped schema.
- **GUCs** (`pg_ripple.sparql_max_algebra_depth` and ~40 others). These are per-database or
  per-session settings; `ALTER DATABASE … SET` in a migration is possible but belongs in a
  later release once the useful subset is clear.
- **Embeddings, KGE training, PageRank runs, tenants, RLS grants.** Each is a plausible v2
  object kind. Tenants (`_pg_ripple.tenants`) and graph grants (`_pg_ripple.graph_access`) are
  the two with clean catalogs and would come first.

## 2. The naming rule, applied up front

Every method mixed into `ActiveRecord::ConnectionAdapters::AbstractAdapter` — public **and
private** — carries a `ripple_` element. Not cosmetic: `pg_cron-rails` shipped a private
`resolve_sql_definition` that shadowed `fx`'s same-named method with a different arity and broke
every `create_function` in any app running both gems. An app using pg_ripple is likely to be
running `fx` too.

```ruby
create_ripple_prefix     drop_ripple_prefix
create_ripple_shapes     update_ripple_shapes     drop_ripple_shapes
create_ripple_rules      update_ripple_rules      drop_ripple_rules
create_ripple_sparql_view update_ripple_sparql_view drop_ripple_sparql_view
create_ripple_endpoint   drop_ripple_endpoint

# private
resolve_ripple_sql_definition
validate_ripple_version_or_definition_present!
validate_ripple_version_and_definition_exclusive!
```

`spec/pg_ripple/coexistence_spec.rb` loads `fx` *and* `pg_cron` alongside this gem and asserts
all three DSLs still work. Both are development dependencies for that reason alone.

## 3. Definition files are not all SQL

`fx` and `pg_cron` both resolve `(name, version)` to a `.sql` file. pg_ripple's payloads are not
SQL — they are Turtle, Datalog, and SPARQL, passed as a string argument to a function call. So
`PgRipple::Definition` keeps fx's lookup logic (engine `db/migrate` siblings first, then
`Rails.root`) and parameterises the extension:

```
db/ripple/shapes/person_v01.ttl   → load_shacl($ttl$…$ttl$)
db/ripple/rules/org_chart_v01.dl  → load_rules('org_chart', $dl$…$dl$)
db/ripple/views/people_v01.rq     → create_sparql_view('people', $rq$…$rq$)
```

Real file extensions mean editors, linters and GitHub all syntax-highlight them, and a SPARQL
query is checkable by `rapper`/`arq` in CI. The adapter dollar-quotes the body with a
kind-specific tag; a Turtle document is full of `"` and `'`, and `$$` alone would collide with
nothing here but reads worse in a dump.

**The adapter never interpolates the body into SQL by string concatenation.** It binds the
document as a parameter (`SELECT pg_ripple.load_shacl($1)`), which pg_cron could not do for
`cron.schedule` but this can.

## 4. The dumper, and the one thing that will not round-trip

Check what each catalog retains before writing `#to_schema` — this is where the design work is.

| Kind | Round-trips? | Source |
|---|---|---|
| Prefixes | yes | `_pg_ripple.prefixes (prefix, expansion)` — read the table; there is no `list_prefixes()` |
| Rule sets | yes | `_pg_ripple.rules.rule_text`, verbatim, one row per rule ordered by `id`, grouped by `rule_set`; `rule_sets.active` gives the enabled flag |
| SPARQL views | yes | `_pg_ripple.sparql_views.sparql` keeps the original query text verbatim — dump `schedule` and `decode` with it |
| Endpoints | yes | `_pg_ripple.federation_endpoints (url, enabled, local_view_name, complexity)`, keyed on `url` |
| **SHACL shapes** | **no** | `_pg_ripple.shacl_shapes` stores `shape_json JSONB` — the *parsed* shape. The Turtle you loaded is gone, and there is no `export_shacl()`. |

The shape loss is worse than formatting: `sh:severity`, `sh:name`, `sh:description` and
`sh:order` are dropped outright, so even a semantically-regenerated Turtle would validate
*differently* from the source. A multi-shape document is shredded into one independent row per
shape with no grouping key, so the catalog cannot say which definition file a shape came from.
`export_turtle()` is not a back door — `load_shacl` never puts the shape triples in the store.
Evidence in [`docs/probe-results.md` §d](docs/probe-results.md#d-what-does-_pg_rippleshacl_shapesshape_json-contain--is-turtle-recoverable).

So shapes are the exception, and pretending otherwise would produce a `schema.rb` that loads a
different validation surface than the migrations built. The dumper emits, instead of a
reconstructed `load_shacl`:

```ruby
# pg_ripple: 4 SHACL shapes are loaded in this database. Their source is not
# recoverable from the catalog (see db/ripple/shapes). A database restored from
# schema.rb alone will have no shapes — use `rake pg_ripple:shapes:load`.
#   <https://example.org/PersonShape> (targets ex:Person, 3 properties)
```

`rake pg_ripple:shapes:load` replays every file in `db/ripple/shapes` at its highest version,
and is wired into `db:schema:load` via an enhancement so a `schema.rb`-restored database is
still correct. Concurrently, file an upstream issue asking for `export_shacl(shape_iri)`; if it
lands, shapes join the table above and the rake task becomes a fallback.

Dump ordering, after `super` in `#tables`:
prefixes → shapes → rule sets → views → endpoints. Views reference prefixes. Expose
`dump_ripple_objects_at_beginning_of_schema` for the fx reason (a column default calling into
the store), defaulting to `false`.

## 5. Guarding on the extension

Mirror `pg_cron.pg_cron_enabled?`, with one addition — pg_ripple requires PostgreSQL 18+ and
carries its own catalog version:

```ruby
def pg_ripple_enabled?   # SELECT 1 FROM pg_extension WHERE extname = 'pg_ripple'
def pg_ripple_version    # SELECT extversion FROM pg_extension WHERE extname = 'pg_ripple'
def pg_trickle_enabled?  # SELECT 1 FROM pg_extension WHERE extname = 'pg_trickle'
```

`pg_ripple_version` reads `pg_extension`, **not** `_pg_ripple.schema_version`. That table is an
internal catalog-migration ledger: 33 rows on a fresh 0.128.0 install, top row `0.98.0`, all
inserted within the same millisecond so `ORDER BY installed_at DESC LIMIT 1` is a tie-break and
is not even stable. `pg_extension.extversion` matches the image's
`org.opencontainers.image.version` label, so `rake pg_ripple:status` and CI agree.

`pg_trickle_enabled?` is a **second** guard, needed only by the SPARQL-view statements.
pg_trickle is a soft dependency: the published image ships it, but `CREATE EXTENSION pg_ripple`
does not install it and `CASCADE` does not pull it in, and `create_sparql_view` errors out
without it. `pg_ripple_enabled?` alone is not sufficient there.

Statements no-op when the extension is absent; catalog readers return `[]` so `db:schema:dump`
survives a database without it. `pg_ripple_version` is not enforced in v1 — it is surfaced by
`rake pg_ripple:status` and recorded in a comment at the top of the dumped section, so a schema
diff shows when the extension moved under the app.

## 6. Build phases

Each phase ends green: `bundle exec rspec && bundle exec standardrb`.

1. **Scaffold.** `pg_ripple.gemspec` (`activerecord`/`activesupport`/`railties >= 7.0`; dev deps
   `pg`, `rspec-rails`, `standard`, `yard`, `fx`, `pg_cron`), `Gemfile`, `Rakefile`, `bin/setup`,
   `bin/console`, `bin/rspec`, `LICENSE` (MIT), `lib/pg_ripple/version.rb`, `railtie.rb`,
   `configuration.rb`, and `PgRipple.load` wiring the three mix-ins.
2. **Adapter.** `adapters/postgres.rb` plus `connection.rb` and one reader per kind
   (`prefixes.rb`, `rule_sets.rb`, `shapes.rb`, `sparql_views.rb`, `endpoints.rb`),
   each returning value objects. Parameter binding, not interpolation.
3. **Definition + Statements + CommandRecorder.** Five kinds × create/update/drop, `ripple_`-prefixed,
   with `revert_to_version` inversion.
4. **Value objects + SchemaDumper**, including the shapes-are-lossy comment path.
5. **Generators.** `rails g pg_ripple:shapes`, `:rules`, `:view`, `:prefix`, `:endpoint`
   — fx's `migration_helper` / `name_helper` / `version_helper` verbatim, with per-kind
   `create_*.erb` / `update_*.erb` templates and a `USAGE`. The `:rules` template must emit RDF
   triple-pattern Datalog (`?x <ex:p> ?y :- ?x <ex:q> ?y .`), not predicate terms — the parser
   rejects anything that is not a 3-term triple pattern. The `:view` USAGE must say pg_trickle is
   required.
6. **Rake tasks.** `pg_ripple:status`, `shapes:load`, `rules:load`, `infer`, `validate`,
   `seeds:load`, and the `db:schema:load` enhancement.
7. **Tests.** `spec/dummy` (minimal Rails app), unit specs mirroring `lib/`, `spec/features/*/migrations_spec.rb`
   and `revert_spec.rb` against a real pg_ripple database, `spec/acceptance/` driving the
   generators, and `spec/pg_ripple/coexistence_spec.rb`.
8. **CI + docs.** Ruby × Rails matrix on `ghcr.io/trickle-labs/pg-ripple:0.128.0` as a service
   container (stock `postgres:18` will not do). The setup step must run **both**
   `CREATE EXTENSION pg_ripple` and `CREATE EXTENSION pg_trickle` — the image ships pg_trickle but
   installs neither, and `CASCADE` does not pull it in. README with a worked example per object
   kind, CHANGELOG, and the honest limitations section covering SHACL round-tripping and the
   absence of named graphs.

## 7. Questions settled by the probe

All answered against a live pg_ripple 0.128.0 database in phase 1. Full SQL and output in
[`docs/probe-results.md`](docs/probe-results.md); the answers are folded into the sections above.

- **Is `load_shacl` additive or replacing?** **Replacing per shape IRI, additive across the shape
  set.** `shacl_shapes` is keyed on `shape_iri` and `load_shacl` upserts the whole JSON document,
  so redefining a shape does not merge its properties. For IRIs in both the old and new version
  `update_ripple_shapes` is therefore a single `load_shacl` call. The one gap is an IRI the old
  file declared and the new one does not: it is orphaned and still validating, and the catalog
  carries no provenance to find it. `update_ripple_shapes` collects declared IRIs from the
  *previous version's file on disk* — `^\s*(\S+:\S+|<[^>]+>)\s+a\s+sh:NodeShape` is enough, no
  Turtle parser — and drops the ones the new version omits. Still worth asking upstream for
  `load_shacl(turtle, replace := true)` and a `source` column.
- **Does `load_rules` replace a rule set of the same name?** **Replaces** — delete-then-insert,
  proved by the identity sequence advancing. So `update_ripple_rules` is a single `load_rules`
  call. The `drop_rules` + `load_rules` pair is not merely unnecessary but worse: `drop_rules`
  retracts materialised inferences that a straight reload keeps.
- **Do `create_sparql_view` and `drop_graph` participate in transactions?** **Yes, all of them,
  fully.** A rollback of a transaction that created a graph, shape, rule set, prefix, endpoint and
  SPARQL view — and dropped one of each baseline object — restored the database exactly, including
  the pg_trickle stream table and its backing relations. Nothing commits internally, migrations
  are atomic, and the README needs no caveat.
- **Published extension image tag** for CI: **`ghcr.io/trickle-labs/pg-ripple:0.128.0`**. Only
  `latest`, `0.128.0` and `0.128` are published — no `v`-prefix, no PostgreSQL-major tag.

Two things the probe forced out that were not asked, both blocking for phase 3:

- **`create_sparql_view` fails on any name that does not already exist**, in 0.128.0 against
  pg_trickle 0.68.0. It unconditionally calls `pgtrickle.drop_stream_table` for idempotence
  (upstream issue #83) and pg_trickle raises a hard `ERROR` when the table is absent. File the
  upstream issue; until it lands `create_ripple_sparql_view` should raise a clear error pointing
  at it rather than silently pre-creating a placeholder stream table.
- **SPARQL views cannot be tested against an empty database.** View compilation of a query whose
  predicates are absent from the store produces table-less SQL that pg_trickle rejects. The
  feature specs must load triples before creating a view.

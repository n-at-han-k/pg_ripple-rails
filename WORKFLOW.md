# Building the `pg_ripple` Rails gem

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
the application's queries work. Six kinds:

| Object | Create | Drop | Catalog | Definition file |
|---|---|---|---|---|
| Named graph | `create_graph(iri)` | `drop_graph(iri)` | `list_graphs()` | — (name is the IRI) |
| Prefix | `register_prefix(prefix, iri)` | — | `_pg_ripple.prefixes` | — (two scalars) |
| SHACL shape set | `load_shacl(turtle)` | `drop_shape(iri)` | `_pg_ripple.shacl_shapes` | `db/ripple/shapes/<name>_v01.ttl` |
| Datalog rule set | `load_rules(name, program)` | `drop_rules(name)` | `_pg_ripple.rules` | `db/ripple/rules/<name>_v01.dl` |
| SPARQL view | `create_sparql_view(name, query)` | `drop_sparql_view(name)` | `_pg_ripple.sparql_views` | `db/ripple/views/<name>_v01.rq` |
| Federation endpoint | `register_endpoint(name, url)` | `remove_endpoint(name)` | `_pg_ripple.federation_endpoints` | — (two scalars) |

Deliberately out of scope for v1, with reasons:

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
create_ripple_graph      drop_ripple_graph
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
| Graphs | yes | `list_graphs()` returns the IRI |
| Prefixes | yes | `_pg_ripple.prefixes (prefix, expansion)` |
| Rule sets | yes | `_pg_ripple.rules.rule_text`, one row per rule, grouped by `rule_set`; `rule_sets.active` gives the enabled flag |
| SPARQL views | yes | `_pg_ripple.sparql_views.sparql` keeps the original query text |
| Endpoints | yes | `_pg_ripple.federation_endpoints (url, enabled, local_view_name)` |
| **SHACL shapes** | **no** | `_pg_ripple.shacl_shapes` stores `shape_json JSONB` — the *parsed* shape. The Turtle you loaded is gone, and there is no `export_shacl()`. |

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
prefixes → graphs → shapes → rule sets → views → endpoints. Views reference prefixes and
graphs; rules reference predicates the graphs hold. Expose
`dump_ripple_objects_at_beginning_of_schema` for the fx reason (a column default calling into
the store), defaulting to `false`.

## 5. Guarding on the extension

Mirror `pg_cron.pg_cron_enabled?`, with one addition — pg_ripple requires PostgreSQL 18+ and
carries its own catalog version:

```ruby
def pg_ripple_enabled?   # SELECT 1 FROM pg_extension WHERE extname = 'pg_ripple'
def pg_ripple_version    # SELECT version FROM _pg_ripple.schema_version ORDER BY installed_at DESC LIMIT 1
```

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
   (`graphs.rb`, `prefixes.rb`, `rule_sets.rb`, `shapes.rb`, `sparql_views.rb`, `endpoints.rb`),
   each returning value objects. Parameter binding, not interpolation.
3. **Definition + Statements + CommandRecorder.** Six kinds × create/update/drop, `ripple_`-prefixed,
   with `revert_to_version` inversion.
4. **Value objects + SchemaDumper**, including the shapes-are-lossy comment path.
5. **Generators.** `rails g pg_ripple:shapes`, `:rules`, `:view`, `:graph`, `:prefix`, `:endpoint`
   — fx's `migration_helper` / `name_helper` / `version_helper` verbatim, with per-kind
   `create_*.erb` / `update_*.erb` templates and a `USAGE`.
6. **Rake tasks.** `pg_ripple:status`, `shapes:load`, `rules:load`, `infer`, `validate`,
   `seeds:load`, and the `db:schema:load` enhancement.
7. **Tests.** `spec/dummy` (minimal Rails app), unit specs mirroring `lib/`, `spec/features/*/migrations_spec.rb`
   and `revert_spec.rb` against a real pg_ripple database, `spec/acceptance/` driving the
   generators, and `spec/pg_ripple/coexistence_spec.rb`.
8. **CI + docs.** Ruby × Rails matrix on a pg_ripple service image (`docker/` upstream builds
   one — confirm the published tag before pinning; stock `postgres:18` will not do), README with
   a worked example per object kind, CHANGELOG, and the honest limitations section covering
   SHACL round-tripping.

## 7. Open questions to settle before phase 3

- **Is `load_shacl` additive or replacing?** It returns the count of shapes loaded. If loading a
  document that redefines an existing `sh:NodeShape` merges rather than replaces,
  `update_ripple_shapes` must `drop_shape` each IRI in the old version first — which means the
  gem has to know which IRIs a definition file declares. Parsing Turtle in Ruby to find them is
  the fallback; ask upstream for `load_shacl(turtle, replace := true)` first.
- **Does `load_rules` replace a rule set of the same name?** Same question, cheaper answer:
  `drop_rules(name)` then `load_rules` inside one transaction is correct either way.
- **Do `create_sparql_view` and `drop_graph` participate in transactions?** pgrx functions that
  do DDL through SPI normally do. If any of them commit internally, migrations wrapping them are
  not atomic and the README must say so.
- **Published extension image tag** for CI.

Each is answered by a probe against a live pg_ripple database, not by reading the docs.

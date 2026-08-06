export const meta = {
  name: 'build-pg-ripple-rails',
  description: 'Build the pg_ripple Rails gem, phase by phase, in the shape of fx and pg_cron-rails',
  whenToUse:
    'Run from the root of pg_ripple-rails with references/fx, references/pg_cron-rails and references/pg-ripple checked out. Implements the plan in WORKFLOW.md. Pass args: {phases: [1,2]} to run a subset; omit args to run all nine.',
  phases: [
    { title: 'Probe', detail: 'answer the open questions against a live pg_ripple database' },
    { title: 'Scaffold', detail: 'gemspec, Gemfile, Rakefile, bin/, version, railtie, configuration' },
    { title: 'Adapter', detail: 'connection, enabled? guard, one catalog reader per object kind' },
    { title: 'DSL', detail: 'Definition, Statements, CommandRecorder — all ripple_-prefixed' },
    { title: 'Dumper', detail: 'value objects and SchemaDumper, including the lossy-shapes path' },
    { title: 'Generators', detail: 'rails g pg_ripple:{shapes,rules,view,graph,prefix,endpoint}' },
    { title: 'Tasks', detail: 'rake tasks and the db:schema:load enhancement' },
    { title: 'Tests', detail: 'dummy app, unit, feature, revert, acceptance, coexistence specs' },
    { title: 'Ship', detail: 'CI matrix, README, CHANGELOG, and a full green run' },
  ],
}

// ── Shared context every agent gets ──────────────────────────────────────────
//
// The plan is in the repo. Restating it inline would let the two drift, so
// agents are pointed at it and told to read it. WORKFLOW.md section numbers are
// stable enough to reference.

const REPO = 'the pg_ripple-rails repo you are running in'

const CONTEXT = `
You are building the \`pg_ripple\` Rails gem in ${REPO}.

REQUIRED READING, in this order, before you write anything:
  1. WORKFLOW.md — the plan. Sections are numbered; your phase names its own.
  2. docs/reference-gem-structure.md — what fx and pg_cron-rails do and why.
  3. references/fx/lib/fx/ and references/pg_cron-rails/lib/pg_cron/ — the code
     itself. Match its idiom: same file layout, same doc-comment density, same
     level of "why" in comments where a choice is non-obvious.
  4. references/pg-ripple/docs/src/reference/sql-functions.md for signatures,
     and \`grep -rh 'CREATE TABLE IF NOT EXISTS _pg_ripple' references/pg-ripple/src references/pg-ripple/sql\`
     for the catalog columns you read.

NON-NEGOTIABLE:
  - Every method mixed into ActiveRecord::ConnectionAdapters::AbstractAdapter,
    public AND private, contains \`ripple_\`. WORKFLOW.md section 2 explains what
    breaks otherwise. This is the single most important rule in the build.
  - Documents (Turtle, Datalog, SPARQL) are BOUND as query parameters, never
    interpolated into a SQL string.
  - Ruby style is standardrb. Frozen string literals. No new runtime deps.
  - Do not invent pg_ripple SQL functions. If the function you need does not
    appear in sql-functions.md or the extension source, say so in your return
    value rather than calling it.
  - CONTAINERS: this machine runs other people's containers, including a live
    pg_ripple one (\`ontology-ripple\`, 127.0.0.1:15432) and a tradeportal stack.
    Never exec into, stop, restart or remove a container you did not create, and
    never connect to one — a probe or test run writes and drops schema objects.
    If you need a database, create your OWN throwaway container from
    ghcr.io/trickle-labs/pg-ripple:latest with a name unique to your phase,
    \`--rm\`, an ephemeral published port (\`-p 127.0.0.1:0:5432\`), and no volume
    or network attachments; remove it before you finish. Never run
    \`docker system prune\` or any other bulk container/image/volume/network
    command.

Return a terse report: files written, decisions taken that WORKFLOW.md did not
already settle, and anything you could not do.
`

const PHASES = [
  {
    n: 1,
    title: 'Probe',
    prompt: `${CONTEXT}

PHASE 1 — Probe. Answer WORKFLOW.md section 7's open questions empirically.

Get a pg_ripple database. The image \`ghcr.io/trickle-labs/pg-ripple:latest\` is
ALREADY PULLED on this machine — run it rather than building from
references/pg-ripple/Dockerfile. There is no psql on the host PATH, so drive it
with \`docker exec <container> psql -U postgres\`. If you cannot get one running
inside ~10 minutes, STOP and report that — do not guess the answers, and do not
spend the rest of the phase fighting the build.

CONTAINER ISOLATION — HARD RULES. This machine has other people's containers
running, INCLUDING a live pg_ripple one called \`ontology-ripple\` on
127.0.0.1:15432, plus a tradeportal stack. Your probe writes and drops schema
objects, so touching any of them would destroy real work.

  - NEVER use, exec into, restart, stop or remove a container you did not create.
    \`ontology-ripple\` is off limits — do not connect to port 15432 at all.
  - Create exactly ONE container, named \`pg-ripple-rails-probe\`, from that image:
      docker run -d --rm --name pg-ripple-rails-probe \\
        -e POSTGRES_PASSWORD=probe -e POSTGRES_DB=probe \\
        -p 127.0.0.1:0:5432 ghcr.io/trickle-labs/pg-ripple:latest
    The \`-p 127.0.0.1:0:5432\` asks the kernel for a free ephemeral port — never
    hardcode a host port, and read the assigned one back with \`docker port\`.
    Prefer \`docker exec\` over the host port entirely.
  - No volume mounts, no bind mounts, no --network joining an existing network,
    no docker compose. The container must own nothing that outlives it.
  - If the name is already taken, pick \`pg-ripple-rails-probe-2\` etc. Do not
    remove the existing one.
  - Remove your container at the end of the phase, pass or fail:
    \`docker rm -f pg-ripple-rails-probe\`. Do not run \`docker system prune\`,
    \`docker container prune\`, or any other command that acts on containers,
    images, volumes or networks in bulk.

Record in your report the exact container name you used and confirmation that
you removed it.

With a database, determine by experiment:
  a. Is load_shacl() additive or replacing when a shape IRI is redefined?
  b. Does load_rules() replace a same-named rule set, or append?
  c. Do create_sparql_view / drop_graph / load_shacl roll back inside an aborted
     transaction, or do they commit internally?
  d. What exactly does _pg_ripple.shacl_shapes.shape_json contain — is the
     original Turtle recoverable from it after all?
  e. The published container image tag carrying the extension, for CI.

Write the findings to docs/probe-results.md, one section per question, each with
the SQL you ran and its output. Where an answer contradicts WORKFLOW.md, update
WORKFLOW.md and say so loudly in your report — later phases build on it.`,
  },
  {
    n: 2,
    title: 'Scaffold',
    prompt: `${CONTEXT}

PHASE 2 — Scaffold. WORKFLOW.md section 6.1.

pg_ripple.gemspec (runtime: activerecord/activesupport/railties >= 7.0; dev: pg,
rspec-rails, standard, yard, fx, pg_cron), Gemfile, Rakefile, bin/setup,
bin/console, bin/rspec, bin/standardrb, .standard.yml, .rspec, .yardopts, LICENSE
(MIT), CHANGELOG.md, and under lib/: pg_ripple.rb, pg_ripple/version.rb,
pg_ripple/railtie.rb, pg_ripple/configuration.rb.

PgRipple.load does the three mix-ins in fx's order. Configuration carries the
adapter and dump_ripple_objects_at_beginning_of_schema (default false). Everything
downstream is required but not yet written — leave the requires in place and let
this phase's only check be that the files parse (\`ruby -c\`).`,
  },
  {
    n: 3,
    title: 'Adapter',
    prompt: `${CONTEXT}

PHASE 3 — Adapter. WORKFLOW.md sections 1 and 5.

lib/pg_ripple/adapters/postgres.rb, plus postgres/connection.rb and one reader per
object kind: graphs, prefixes, rule_sets, shapes, sparql_views, endpoints. Each
reader owns exactly one catalog query and returns value objects (which phase 5
defines — declare the classes minimally here if you need them to exist).

The adapter carries pg_ripple_enabled? and pg_ripple_version, every write method
no-ops when the extension is absent, and every reader returns [] then.

Read the catalog columns from the extension source, not from memory. Note in your
report any kind whose catalog turns out to retain less than WORKFLOW.md's table
claims.`,
  },
  {
    n: 4,
    title: 'DSL',
    prompt: `${CONTEXT}

PHASE 4 — DSL. WORKFLOW.md sections 2 and 3.

lib/pg_ripple/definition.rb — fx's Definition, parameterised over kind so it maps
(:shapes, name, version) to db/ripple/shapes/<name>_v01.ttl, (:rules, …) to .dl,
(:views, …) to .rq. Keep fx's engine-migration-path lookup.

lib/pg_ripple/statements.rb — create/update/drop for all six kinds. Graphs,
prefixes and endpoints take scalars and have no definition file; shapes, rules and
views take version: or sql_definition: (name it \`definition:\` — it is not SQL)
and are mutually exclusive per fx.

lib/pg_ripple/command_recorder.rb — record + invert for each, with
revert_to_version inversion and ruby2_keywords, following fx exactly.

EVERY name here, private helpers included, contains ripple_.`,
  },
  {
    n: 5,
    title: 'Dumper',
    prompt: `${CONTEXT}

PHASE 5 — Dumper. WORKFLOW.md section 4 — read it in full; the SHACL case is the
whole point of this phase.

One value object per kind under lib/pg_ripple/ with #to_schema emitting the
matching create_ripple_* call, plus lib/pg_ripple/schema_dumper.rb prepended to
ActiveRecord::SchemaDumper, hooking #tables (NOT #extensions — see the reference
doc), dumping in the order prefixes → graphs → shapes → rule sets → views →
endpoints after super, honouring the beginning-of-schema flag.

Shapes do not round-trip: emit the explanatory comment block from WORKFLOW.md
section 4, listing each shape IRI with its target and property count, NOT a
fabricated load_shacl call. If phase 1's probe found the Turtle IS recoverable
from shape_json, do it properly instead and note the change.

Rule sets dump as one create_ripple_rules with the rule_text rows joined by
newline, followed by disable_ripple_rules when the set is inactive.`,
  },
  {
    n: 6,
    title: 'Generators',
    prompt: `${CONTEXT}

PHASE 6 — Generators. WORKFLOW.md section 6.5.

lib/generators/pg_ripple/{shapes,rules,view,graph,prefix,endpoint}/ with a
generator, a USAGE, and create_*.erb / update_*.erb migration templates. Lift
fx's migration_helper.rb, name_helper.rb and version_helper.rb — they are
kind-agnostic and there is no reason to rewrite them.

The three file-backed kinds also create the definition file itself
(db/ripple/shapes/<name>_v01.ttl etc.), seeded with a commented skeleton of the
right language, and bump to _v02 when one already exists — that is what
version_helper is for.`,
  },
  {
    n: 7,
    title: 'Tasks',
    prompt: `${CONTEXT}

PHASE 7 — Rake tasks. WORKFLOW.md section 6.6.

lib/tasks/pg_ripple/*.rake, loaded by the railtie's rake_tasks block the way
pg_cron-rails does it: status (extension presence, version, counts per kind),
shapes:load, rules:load, seeds:load, infer, validate.

shapes:load replays the highest version of every file in db/ripple/shapes and is
attached to db:schema:load by enhancement, because a schema.rb-restored database
has no shapes. Make the enhancement a no-op when the extension is absent.`,
  },
  {
    n: 8,
    title: 'Tests',
    prompt: `${CONTEXT}

PHASE 8 — Tests. WORKFLOW.md section 6.7. Copy references/fx/spec's layout.

  - spec/dummy: minimal Rails app (application.rb, boot.rb, environment.rb,
    database.yml, config.ru, Rakefile, bin/, db/migrate/.keep). Nothing more.
  - spec/pg_ripple/*: unit specs mirroring lib/, doubles for the connection.
  - spec/features/<kind>/migrations_spec.rb and revert_spec.rb: real migrations
    against a real pg_ripple database.
  - spec/acceptance/*: the generators end to end.
  - spec/pg_ripple/coexistence_spec.rb: load fx AND pg_cron alongside this gem and
    assert create_function, create_cron_job and create_ripple_rules all still
    work. This spec is why both are dev dependencies. If it fails, the fix is
    renaming OUR method, never theirs.

Run \`bundle exec rspec\`. Report the actual pass/fail counts, including specs
skipped for want of a database — do not report green if anything was skipped.`,
  },
  {
    n: 9,
    title: 'Ship',
    prompt: `${CONTEXT}

PHASE 9 — Ship. WORKFLOW.md section 6.8.

.github/workflows/ci.yml: Ruby × Rails matrix on a pg_ripple service container
using the image phase 1 identified (stock postgres:18 lacks the extension — if no
published image exists, build it in a setup step and say so in the README).

README.md: what the gem manages and what it deliberately does not (WORKFLOW.md
section 1), a worked example per object kind, the schema.rb round-trip
limitation for SHACL stated plainly, and installation including the PostgreSQL 18
requirement. CHANGELOG.md for 0.1.0.

Then a full verification run: bundle exec standardrb, bundle exec rspec, and a
migrate → schema:dump → schema:load → migrate round trip in spec/dummy. Report
each command's real outcome.`,
  },
]

// ── Run ──────────────────────────────────────────────────────────────────────
//
// Sequential, not parallel, and deliberately so: each phase writes files the
// next one reads, and phase 1 can rewrite the plan the rest follow. A barrier
// between every pair is the correct shape here — there is no independent work to
// overlap.

const requested = args?.phases
const selected = requested
  ? PHASES.filter((p) => requested.includes(p.n))
  : PHASES

if (selected.length === 0) {
  log(`No phases matched ${JSON.stringify(requested)} — expected numbers 1..${PHASES.length}`)
  return { ran: [], reports: {} }
}

const REPORT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['files_written', 'decisions', 'blocked', 'verified'],
  properties: {
    files_written: { type: 'array', items: { type: 'string' } },
    decisions: {
      type: 'array',
      items: { type: 'string' },
      description: 'Choices made that WORKFLOW.md did not already settle',
    },
    blocked: {
      type: 'array',
      items: { type: 'string' },
      description: 'Anything attempted and not completed, with the reason',
    },
    verified: {
      type: 'string',
      description: 'Commands actually run and their real outcome, or "none" if nothing was run',
    },
  },
}

const reports = {}

for (const p of selected) {
  phase(p.title)

  const prior = Object.entries(reports)
    .map(([title, r]) => `## ${title}\n${JSON.stringify(r, null, 2)}`)
    .join('\n\n')

  const carry = prior
    ? `\n\nEARLIER PHASES REPORTED:\n${prior}\n\nTreat their decisions as settled and their blocked items as still open.`
    : ''

  const report = await agent(p.prompt + carry, {
    label: `phase-${p.n}:${p.title.toLowerCase()}`,
    phase: p.title,
    schema: REPORT_SCHEMA,
  })

  if (!report) {
    log(`Phase ${p.n} (${p.title}) returned nothing — stopping so later phases do not build on a gap.`)
    break
  }

  reports[p.title] = report
  log(
    `Phase ${p.n} ${p.title}: ${report.files_written.length} files` +
      (report.blocked.length ? `, ${report.blocked.length} BLOCKED` : ''),
  )

  // Only ONE probe failure invalidates the rest of the build: not getting a
  // database at all, which would make every later phase guesswork. An upstream
  // bug the probe found and documented is a RESULT, not a blocker — the first
  // run stopped the whole build on exactly that, which was wrong.
  if (p.n === 1 && /^none$/i.test(report.verified.trim())) {
    log('Probe ran nothing against a live database. Later phases would be guessing — stopping here.')
    break
  }
}

return {
  ran: Object.keys(reports),
  blocked: Object.entries(reports).flatMap(([title, r]) =>
    r.blocked.map((b) => `${title}: ${b}`),
  ),
  reports,
}

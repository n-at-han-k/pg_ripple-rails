export const meta = {
  name: 'build-vertical-slice',
  description: 'Build the vertical slice of pg_ripple-rails that proves the README spec: Node mixin, diff writes, lateral-join relations',
  whenToUse:
    'Run from the root of pg_ripple-rails once README.md is the design spec and docs/spec-corrections.md exists. Builds the thinnest path through the spec that is end-to-end real: a model with an iri column, graph properties, diff-based writes, and graph associations that return ActiveRecord::Relation. Everything else in the README is additive on top.',
  phases: [
    { title: 'Probe', detail: 'settle the lateral join empirically before any Ruby depends on it' },
    { title: 'Foundation', detail: 'gemspec, config, and the RDF::Repository over the AR connection' },
    { title: 'Paths', detail: 'PgRipple::Path — the SPARQL property-path DSL on StringBuilder' },
    { title: 'Node', detail: 'the PgRipple::Node mixin and the graph/property DSL' },
    { title: 'Writes', detail: 'diff-based persistence strategy inside the ActiveRecord transaction' },
    { title: 'Relations', detail: 'graph_has_many / .graph.where returning ActiveRecord::Relation' },
    { title: 'Specs', detail: 'dummy app and feature specs against a real pg_ripple database' },
    { title: 'Review', detail: 'adversarial check of emitted SQL and SPARQL against the spec' },
    { title: 'Report', detail: 'run everything, reconcile the README, report honestly' },
  ],
}

// ── What every agent needs to know ───────────────────────────────────────────
//
// The spec is README.md and it is long. Agents are pointed at the sections that
// bind them rather than handed a summary, because a summary is one more thing to
// drift. docs/spec-corrections.md overrides README wherever they disagree — that
// file is empirical, README is aspirational.

const CONTEXT = `
You are building the gem \`pg_ripple-rails\` in the repo you are running in.

REQUIRED READING before you write anything:
  1. README.md — the design spec. Its code blocks are ACCEPTANCE CRITERIA: the
     Ruby is the API you must provide, and the SPARQL/SQL/Turtle beneath it is
     what that Ruby must emit. Read the sections your phase names.
  2. docs/spec-corrections.md — where the spec is wrong about the real extension.
     THIS FILE WINS over README wherever they disagree. Correction 1 (the lateral
     join projects out of TABLE(result jsonb), not a column definition list) is
     load-bearing for the whole gem.
  3. docs/probe-results.md — real signatures read from pg_proc on a live 0.128.0
     database. The upstream docs are stale; do not trust them over this.
  4. lib/ — the migration and schema-dumping layer already exists and is built in
     the fx idiom. Match its style. Do not rewrite it.
  5. references/fx/lib/fx/ for idiom; references/pg-ripple/src for ground truth
     about the extension.

SETTLED DECISIONS — do not relitigate:
  - Gem name is \`pg_ripple-rails\`; module is \`PgRipple\`. The existing
    pg_ripple.gemspec says \`pg_ripple\` and must be renamed.
  - Methods mixed into ActiveRecord::ConnectionAdapters::AbstractAdapter keep
    their \`ripple_\` prefix (an unprefixed one shadows fx's for the whole host
    app — see docs/reference-gem-structure.md). The spec's shorter names
    (create_shape, create_ruleset) are exposed inside a \`ripple do … end\`
    migration block, which is a receiver we own. This resolves
    docs/spec-corrections.md §4.
  - Dependencies are published and pinnable: rdf 3.3.4, active-triples 1.2.0,
    sparql 3.3.2, string_builder 1.2.4, neighbor 1.2.0.
  - Named graphs are NOT a schema object (probe §3). Do not add them back.

SCOPE — this is a VERTICAL SLICE, not the whole README. In scope: Install,
Models, Property paths, Graph associations, Querying, Transactions, How writes
work, and the Testing matchers those need. OUT of scope for this run: Preloading,
Validations/SHACL generation, Datalog rules, Inference, Explaining, What-if,
Temporal, Multi-tenancy, Change notifications, Vector search, Entity resolution,
Import/export, Background jobs, Graph-native models, HTTP client. Do not stub
them; leave them absent. Say so if your phase seems to need one.

RULES:
  - Ruby style is standardrb. frozen_string_literal. Ruby >= 3.2, Rails >= 7.1.
  - Never interpolate a user value into SPARQL or SQL by string concatenation.
    Bind parameters; build SPARQL through the path/term objects that escape.
  - Do not invent pg_ripple SQL functions. If what you need is not in
    docs/probe-results.md or references/pg-ripple/src, say so and stop.
  - CONTAINERS: this machine runs other people's containers, including a live
    pg_ripple one (\`ontology-ripple\`, 127.0.0.1:15432) and a tradeportal stack.
    NEVER exec into, connect to, stop, restart or remove a container you did not
    create — a test run writes and drops schema objects. If you need a database,
    create your OWN from ghcr.io/trickle-labs/pg-ripple:0.128.0 with a name
    unique to your phase, \`--rm\`, an ephemeral port (\`-p 127.0.0.1:0:5432\`),
    and no volume or network attachments; remove it before you finish. Never run
    \`docker system prune\` or any bulk container/image/volume/network command.

Report tersely: files written, decisions the spec did not settle, anything
blocked, and the REAL outcome of any command you ran.
`

const PHASES = [
  {
    n: 1,
    title: 'Probe',
    prompt: `${CONTEXT}

PHASE 1 — Probe. Settle the lateral join before any Ruby depends on its shape.

docs/spec-corrections.md §1 asserts the corrected SQL from reading
src/sparql_api.rs. Prove it end to end against a live database, and answer the
question that file leaves open.

Stand up your own container (rules above), CREATE EXTENSION pg_ripple, create a
small \`people\` table with an \`iri\` column, load a handful of foaf:knows
triples, then determine:

  a. Does the corrected lateral join actually run and return the right rows?
     Paste the exact SQL and its output.
  b. Does a LIMIT on the OUTER query push through the lateral, or does
     pg_ripple.sparql() materialise every solution first? Use EXPLAIN ANALYZE on
     a path with real fan-out. THIS DECIDES whether the relation builder must
     inject a LIMIT into the SPARQL string, so answer it definitively.
  c. Is the lateral re-executed per outer row, or once? Correlate it to a column
     and compare with the uncorrelated form.
  d. What does result->>'iri' actually contain for an IRI binding — a bare IRI,
     or one wrapped in angle brackets? Same question for a literal: is the
     datatype or language tag in the JSONB, and under what key? Dump raw
     jsonb_pretty output rather than describing it.
  e. Do INSERT DATA via sparql_update() and an ordinary INSERT on the same
     connection roll back together in one transaction? Prove it both ways.
  f. Does sparql_cursor() exist and what is its calling convention? README's
     find_each claims it.

Write docs/probe-lateral-join.md — one section per question, each with the SQL
run and its verbatim output. Update docs/spec-corrections.md §1 with the LIMIT
answer. If (a) fails, STOP and report: the spec's central claim would be wrong
and later phases must not paper over it.`,
  },
  {
    n: 2,
    title: 'Foundation',
    prompt: `${CONTEXT}

PHASE 2 — Foundation. README "Install" and the "Escape hatches" repository.

  - Rename pg_ripple.gemspec to pg_ripple-rails.gemspec, spec.name
    "pg_ripple-rails", and add the runtime deps at the versions listed above.
    Keep the existing dev deps including fx and pg_cron.
  - PgRipple.configure with base_uri, default_graph, validate, strict_loading,
    exactly as README "Install" shows. Fold this into the existing
    lib/pg_ripple/configuration.rb rather than adding a second config object.
  - lib/pg_ripple/repository.rb — an RDF::Repository over
    ActiveRecord::Base.connection. It MUST implement #query_execute so whole
    queries go to Postgres; the README is explicit that per-pattern evaluation
    (SPARQL::Client over a Queryable) is the thing to avoid. Implement
    #insert_statement, #delete_statement, #each_statement, #count and
    #query_execute, mapping solutions out of TABLE(result jsonb) per the probe.
  - The generator \`rails generate pg_ripple:install\` producing exactly the four
    files in README "Install".

RDF::Repository is a real superclass with a real contract — read the rdf 3.3.4
source in the bundle for what #query_execute must return (an enumerable of
RDF::Query::Solution) rather than guessing.`,
  },
  {
    n: 3,
    title: 'Paths',
    prompt: `${CONTEXT}

PHASE 3 — Property paths. README "Property paths" — every operator in that table
is an acceptance criterion.

lib/pg_ripple/path.rb and lib/pg_ripple/handlers/sparql_path.rb, built on
string_builder 1.2.4. Read that gem's source in the bundle FIRST — the README's
sketch (\`handler PgRipple::Handlers::SparqlPath\`) is how the spec imagines the
API, not necessarily what the gem provides. If it differs, follow the gem and
note the divergence.

Operators: / (sequence), | (alternative), unary + (one-or-more), #any
(zero-or-more), #opt (optional), unary ~ (inverse), unary ! (negated set).
Plus #inverse, #to_s, and #to_term returning an RDF::URI only when the path is a
single predicate — and raising, not lying, when it is not.

Precedence is the trap: Ruby's / binds tighter than |, which matches SPARQL, but
unary ~ and + bind tighter than both and \`~ex.worksAt / ex.worksAt\` must come
out as \`^ex:worksAt/ex:worksAt\` and not \`^(ex:worksAt/ex:worksAt)\`. Write the
spec for that case first and make it pass.

Leaf tokens serialise via RDF::Literal#to_base / RDF::URI, never #to_s, so
datatypes, language tags and escaping come from ruby-rdf. Prefixed names require
a prefix registry — decide where it lives and say so.

Unit specs for every row of the README table, exact string equality.`,
  },
  {
    n: 4,
    title: 'Node',
    prompt: `${CONTEXT}

PHASE 4 — The Node mixin. README "Models".

lib/pg_ripple/node.rb providing:
  - \`graph type:, iri:, &block\` class macro, with \`property name, predicate:,
    from:, cast:\` inside it.
  - #iri (String), #rdf_subject (RDF::URI), generated from the iri: lambda
    against config.base_uri, assigned on create and persisted to the iri column.
  - Reader/writer for every property. \`from:\` mirrors an AR column; without it
    the value lives only in the graph and reads through it.
  - #role_values returning the multi-valued array, per README "Where the
    abstraction leaks".
  - PgRipple::UnknownProperty raised for an unknown predicate name.

This wraps ActiveTriples RDFSource/Properties/Configurable — four modules, per
README "Dependencies". Read active-triples 1.2.0 in the bundle before wiring it;
it was extracted from ActiveFedora and its RDFSource contract is not obvious.
If composing it with ApplicationRecord fights you, say so plainly in your report
rather than half-wiring it — that is a real architectural finding, and the README
already flags vendoring as the fallback.

Do NOT implement writes here beyond what is needed to read back what you set in
memory; phase 5 owns persistence.`,
  },
  {
    n: 5,
    title: 'Writes',
    prompt: `${CONTEXT}

PHASE 5 — Diff-based writes. README "How writes work" and "Transactions".

lib/pg_ripple/persistence/diff_strategy.rb. On save, compute the triple delta
from ActiveModel::Dirty on the graph properties and emit ONLY that:

    DELETE DATA { <s> ex:role "engineer" } ;
    INSERT DATA { <s> ex:role "manager" }

never the whole-object rewrite the README shows as the anti-pattern. The three
reasons it matters (delta/main partition churn, CDC subscribers, DRed retraction)
are why this is not a micro-optimisation.

Also:
  - \`graph persistence_strategy: ActiveTriples::RepositoryStrategy\` opts back
    into the default.
  - \`graph dependent: :nullify_references\` additionally emits
    \`DELETE WHERE { ?s ?p <iri> }\` on destroy.
  - Everything runs on ActiveRecord::Base.connection inside the model's existing
    transaction, so rows and triples commit or roll back together. Do not open a
    connection, do not wrap your own transaction around a save.

Write the spec from README "Testing" first — \`expect { alice.update!(role:
"manager") }.to change_triples(by: 1)\` — and the change_triples matcher it needs.`,
  },
  {
    n: 6,
    title: 'Relations',
    prompt: `${CONTEXT}

PHASE 6 — Graph associations and querying. README "Graph associations" and
"Querying". This phase is the thesis: if these do not return a real
ActiveRecord::Relation, the gem's central claim fails.

  - \`graph_has_many\` / \`graph_has_one\` with predicate: or path:, class_name:,
    returning an ActiveRecord::Relation built by joining the SPARQL result
    laterally on the iri column — using the CORRECTED SQL from
    docs/spec-corrections.md §1 as amended by phase 1's probe.
  - \`Model.graph\` returning a chainable proxy supporting where (equality, nil,
    not, Range, Regexp), in_graph, via(path, from:), and composing in both
    directions with ordinary AR scopes.
  - #to_sparql, #to_sql, #explain.
  - \`alice.friends << bob\` and \`.delete(bob)\` emitting INSERT DATA /
    DELETE DATA.
  - find_each streaming, if and only if phase 1 confirmed sparql_cursor's
    convention; otherwise batch on the AR side and say so.

If phase 1 found that LIMIT does not push through the lateral, inject a LIMIT
into the SPARQL string via the sparql gem's AST rather than string-munging.

The acceptance test is README's own line: \`alice.network.where(active: true)
.includes(:account).page(2)\` must work, and \`.class\` must be
ActiveRecord::Relation. Prove it with Kaminari present.`,
  },
  {
    n: 7,
    title: 'Specs',
    prompt: `${CONTEXT}

PHASE 7 — Test suite. README "Testing", plus spec/dummy.

  - spec/dummy: minimal Rails app with a people table carrying an iri column, an
    accounts table for the belongs_to, and a Person model matching README
    "Models". Nothing else.
  - pg_ripple/rspec.rb + PgRipple::TestHelpers, and the matchers the slice needs:
    have_triple, change_triples. (be_derived, violate_shape and entail belong to
    out-of-scope phases — leave them out rather than stubbing them.)
  - Feature specs against a real pg_ripple database, each one an acceptance
    criterion lifted verbatim from the README: the association returns an
    AR::Relation and paginates; a transaction rolls back rows AND triples
    together; an update writes exactly one triple pair; destroy with
    nullify_references sweeps inbound edges; every property-path operator
    round-trips.
  - Transactional fixtures — same connection, so triples roll back with the row.

Stand up your own container per the rules. Run \`bundle exec rspec\` and report
the REAL counts. A spec skipped for want of a database is not a pass; say how
many were skipped and why.`,
  },
]

// ── Run ──────────────────────────────────────────────────────────────────────
//
// Sequential: every phase writes files the next one reads. The one place that
// fans out is Review, where two independent critics with different lenses beat
// one generalist — a wrong emitted-SQL claim survives a friendly read.

const requested = args?.phases
const selected = requested ? PHASES.filter((p) => requested.includes(p.n)) : PHASES

const REPORT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['files_written', 'decisions', 'blocked', 'verified'],
  properties: {
    files_written: { type: 'array', items: { type: 'string' } },
    decisions: { type: 'array', items: { type: 'string' } },
    blocked: { type: 'array', items: { type: 'string' } },
    verified: {
      type: 'string',
      description: 'Commands actually run and their real outcome, or "none"',
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
    log(`Phase ${p.n} (${p.title}) returned nothing — stopping rather than building on a gap.`)
    break
  }

  reports[p.title] = report
  log(
    `Phase ${p.n} ${p.title}: ${report.files_written.length} files` +
      (report.blocked.length ? `, ${report.blocked.length} blocked` : ''),
  )

  // Only one failure invalidates the rest: the probe not reaching a database, or
  // the lateral join not working at all. Everything else is a finding to carry.
  if (p.n === 1 && /^none$/i.test(report.verified.trim())) {
    log('Probe ran nothing against a live database. Stopping — later phases would be guessing.')
    break
  }
}

// ── Review ───────────────────────────────────────────────────────────────────

const built = Object.keys(reports).length

if (built === selected.length && selected.length > 1) {
  phase('Review')

  const LENSES = [
    {
      key: 'emitted',
      prompt: `Review the gem just built in this repo against README.md, adversarially.

Your lens: DOES THE EMITTED SQL AND SPARQL MATCH THE SPEC'S OUTPUT BLOCKS?
For each README section in scope (Models, Property paths, Graph associations,
Querying, Transactions, How writes work), find the code that emits, and check the
real output against the block beneath the Ruby. Run the code where you can — a
claim in a comment is not evidence.

Check especially: the lateral join matches docs/spec-corrections.md §1 as amended
by docs/probe-lateral-join.md; property-path precedence for \`~a / b\`; that a
save emits a delta and not a whole-object rewrite; that nothing interpolates a
value into SPARQL by concatenation.

Default to reporting a discrepancy. A finding that turns out to be wrong costs a
paragraph; a wrong emitted query costs a production incident.`,
    },
    {
      key: 'rails',
      prompt: `Review the gem just built in this repo, adversarially.

Your lens: IS THIS ACTUALLY RAILS-NATIVE, or does it just look like it?
  - Is what graph_has_many returns really an ActiveRecord::Relation — chainable,
    lazy, .merge-able, .to_sql-able — or a lookalike? Prove it in a console.
  - Do triples honestly roll back with ActiveRecord::Base.transaction? Try a
    nested transaction and a raise.
  - Any second connection, connection checkout, or thread-local state that would
    break under a real pool?
  - Does anything mixed into AbstractAdapter lack a ripple_ prefix? That is the
    fx-shadowing bug and it is silent — check every method, private included.
  - Does the gem load cleanly in an app that also has fx and pg_cron?

Run things. Report what fails, not what looks fine.`,
    },
  ]

  const FINDINGS_SCHEMA = {
    type: 'object',
    additionalProperties: false,
    required: ['findings'],
    properties: {
      findings: {
        type: 'array',
        items: {
          type: 'object',
          additionalProperties: false,
          required: ['file', 'summary', 'evidence', 'severity'],
          properties: {
            file: { type: 'string' },
            summary: { type: 'string' },
            evidence: {
              type: 'string',
              description: 'What was run and what it produced — not reasoning',
            },
            severity: { type: 'string', enum: ['high', 'medium', 'low'] },
          },
        },
      },
    },
  }

  const reviews = await parallel(
    LENSES.map((l) => () =>
      agent(`${CONTEXT}\n\n${l.prompt}`, {
        label: `review:${l.key}`,
        phase: 'Review',
        schema: FINDINGS_SCHEMA,
      }),
    ),
  )

  const findings = reviews.filter(Boolean).flatMap((r) => r.findings)
  log(`Review: ${findings.length} findings (${findings.filter((f) => f.severity === 'high').length} high)`)

  reports.Review = { findings }

  // Fix only what the reviewers could evidence, and only the serious ones. A
  // low-severity nit is cheaper for a human to judge than for an agent to
  // "fix" into something else.
  const serious = findings.filter((f) => f.severity !== 'low')

  if (serious.length > 0) {
    phase('Report')

    const fixes = await agent(
      `${CONTEXT}

Two reviewers checked the gem just built. Their findings, with evidence:

${JSON.stringify(serious, null, 2)}

Fix the ones that are REAL. For each, first reproduce the reviewer's evidence
yourself — reviewers are wrong sometimes, and a "fix" for a finding that was
never true makes the code worse. If you cannot reproduce it, mark it not_reproduced
and change nothing.

Then run the full suite (\`bundle exec rspec\`, \`bundle exec standardrb\`), and
finally reconcile README.md: where the built behaviour legitimately differs from
a spec output block, update the block and note it in docs/spec-corrections.md.
Do NOT quietly change the spec to match a bug — only where the spec was wrong
about the extension.

Report the real command outcomes, including failures.`,
      { label: 'fix-and-reconcile', phase: 'Report', schema: REPORT_SCHEMA },
    )

    reports.Fixes = fixes
  }
}

return {
  ran: Object.keys(reports),
  blocked: Object.entries(reports)
    .filter(([, r]) => Array.isArray(r.blocked))
    .flatMap(([title, r]) => r.blocked.map((b) => `${title}: ${b}`)),
  reports,
}

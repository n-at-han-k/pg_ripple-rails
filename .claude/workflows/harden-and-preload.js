export const meta = {
  name: 'harden-and-preload',
  description: 'Fix the connection-handling debt the vertical slice left, then build graph_includes preloading on top',
  whenToUse:
    'Run after build-vertical-slice has landed and the suite is green. Two halves: harden closes the dictionary-cache footgun, the deprecated connection calls, and the open migration-naming decision; preload builds README "Preloading" so graph associations stop being an N+1 generator.',
  phases: [
    { title: 'Diagnose', detail: 'find the real cause of the rolled-back-transaction cache poisoning' },
    { title: 'Connections', detail: 'fix connection handling and export an honest test helper' },
    { title: 'Migrations', detail: 'the ripple do … end block, closing spec-corrections §4' },
    { title: 'FrameProbe', detail: 'establish how sparql_construct_jsonld and framing actually behave' },
    { title: 'Preload', detail: 'graph_includes — one CONSTRUCT, nested documents, hydration by iri' },
    { title: 'Specs', detail: 'acceptance specs proving the N+1 is gone and strict_loading raises' },
    { title: 'Review', detail: 'adversarial check of query counts and connection safety' },
    { title: 'Report', detail: 'reproduce, fix, reconcile the README, report honestly' },
  ],
}

const CONTEXT = `
You are working on the gem \`pg_ripple-rails\` in the repo you are running in.
The vertical slice is BUILT and GREEN: 248 examples, 0 failures against a live
pg_ripple 0.128.0. Do not regress it.

REQUIRED READING before you write anything:
  1. README.md — the design spec. Its code blocks are ACCEPTANCE CRITERIA.
  2. docs/spec-corrections.md — where the spec is wrong about the real
     extension or about the built code. THIS FILE WINS over README.
  3. docs/probe-results.md and docs/probe-lateral-join.md — real signatures and
     real measurements from live databases. The upstream docs are stale; never
     trust them over these.
  4. lib/ and spec/ — what exists. Match the idiom. The suite is the contract:
     if you change behaviour, change the spec that asserts it, in the same
     commit, and say so.

SETTLED — do not relitigate:
  - Gem is \`pg_ripple-rails\`, module \`PgRipple\`.
  - The lateral join projects \`btrim(r.result ->> 'iri', '<>')\` out of
    TABLE(result jsonb). An IRI binding arrives as an N-Triples term string
    WITH angle brackets; a literal carries its datatype or language tag inside
    the same string and must NOT be btrimmed.
  - LIMIT does not push through the lateral (measured: 83ms vs 2.1ms on 25921
    solutions). Injection into the SPARQL is only sound where nothing
    downstream can remove rows.
  - PgRipple::Node COMPOSES ActiveTriples behind a delegate rather than mixing
    RDFSource into ApplicationRecord — mixing it in makes instances immutable
    and replaces id with a blank-node label, and :name/:type/:id/:graph and a
    dozen other property names raise.
  - Named graphs are not a schema object.

RULES:
  - standardrb, frozen_string_literal, Ruby >= 3.2, Rails >= 7.1.
  - Never interpolate a value into SPARQL or SQL by concatenation. Bind.
  - Do not invent pg_ripple SQL functions. If what you need is not in the probe
    docs or references/pg-ripple/src, say so and stop.
  - CONTAINERS: this machine runs other people's containers, including a live
    pg_ripple one (\`ontology-ripple\`, 127.0.0.1:15432) and a tradeportal stack.
    NEVER exec into, connect to, stop, restart or remove a container you did not
    create. Create your OWN from ghcr.io/trickle-labs/pg-ripple:0.128.0 with a
    phase-unique name, \`--rm\`, \`-p 127.0.0.1:0:5432\`, no volume or network;
    set temp_file_limit via ALTER SYSTEM + pg_reload_conf(); remove it before
    you finish. Never run any bulk docker command.
  - The host disk is tight (~4.5 GB free on /). Do not build images. Keep
    fixtures small — a cyclic \`+\` path enumerates PATHS, not nodes, and has
    already exhausted temp space once.
  - Run the suite with \`rspec\` and PG_RIPPLE_TEST_URL set. Report REAL counts.
    A spec skipped for want of a database is not a pass.

Report tersely: files written, decisions the spec did not settle, anything
blocked, and the REAL outcome of every command you ran.
`

const PHASES = [
  {
    n: 1,
    title: 'Diagnose',
    prompt: `${CONTEXT}

PHASE 1 — Diagnose the cache poisoning. Do NOT fix anything yet.

The Rails reviewer found: after a rolled-back transaction, every later SPARQL
read on that same connection returns zero rows. spec/support/database.rb works
around it with disconnect!, and README "Testing" tells host apps the opposite —
that the shared connection means nothing extra is needed.

A workaround that nobody understands is a bug with a longer fuse. Establish what
is actually happening, against your own container:

  a. Reproduce it minimally in SQL alone, no Ruby: BEGIN, insert a triple,
     ROLLBACK, then read. Does it reproduce without ActiveRecord at all? That
     tells you whether this is ours or the extension's.
  b. WHAT is cached — the term dictionary, a prepared plan, a predicate/VP-table
     registry, or the pg_ripple plan cache? \`_pg_ripple.dictionary\`,
     \`dictionary_hot\`, \`predicates\` and \`plan_cache_stats()\` all exist. Find
     which one holds ids for terms the rollback erased.
  c. Is it a session-lifetime cache or a transaction-lifetime one? Does a new
     connection see it? Does \`DISCARD ALL\` clear it? Is there a pg_ripple
     function that clears it (plan_cache_reset, prewarm_dictionary_hot)?
  d. Does it need a ROLLBACK specifically, or does any aborted statement do it?
  e. Does it affect writes too, or only reads?

Write docs/probe-cache-invalidation.md — the minimal reproduction, the answer to
each question with the SQL and its verbatim output, and a recommendation for the
narrowest correct fix. If it turns out to be an extension bug rather than ours,
say so plainly and draft the upstream issue text into the doc; do not paper over
it in Ruby.`,
  },
  {
    n: 2,
    title: 'Connections',
    prompt: `${CONTEXT}

PHASE 2 — Connection handling. Act on phase 1's diagnosis.

  a. Implement the narrowest correct fix for the cache issue. If phase 1 found
     it is the extension's bug, the gem's job is to make it survivable and
     LOUD: a documented helper, not a silent disconnect! buried in the suite.
  b. Export it properly. \`PgRipple::TestHelpers\` should give host apps whatever
     the gem's own suite needs — if spec/support/database.rb calls disconnect!,
     host apps need that too, and today they are told they do not.
  c. Replace every \`ActiveRecord::Base.connection\` call. It is deprecated under
     \`permanent_connection_checkout = :disallowed\` on Rails 8.0.5.1+, and both
     the repository and PgRipple::Node call it — the reviewer reproduced the
     raise. Use \`with_connection\`, and mind that the block form changes
     lifetime: a repository that hands out a connection-bound object cannot
     assume it outlives the block.
  d. Reconcile README "Testing" and "Install" with what is actually true. These
     are the two places the spec currently misleads a host app.

Prove (c) the way the reviewer did: set
\`ActiveRecord.permanent_connection_checkout = :disallowed\` in a spec and show
the calls no longer raise. A grep is not proof.`,
  },
  {
    n: 3,
    title: 'Migrations',
    prompt: `${CONTEXT}

PHASE 3 — Close spec-corrections §4, the last open naming decision.

Option 1 is chosen: \`create_ripple_*\` stay as the names mixed into
AbstractAdapter (an unprefixed one shadows fx's for the whole host app — see
docs/reference-gem-structure.md, and pg_cron-rails shipped exactly that bug),
and README's shorter names live inside a \`ripple do … end\` migration block,
which is a receiver we own.

    class AddOrgRules < ActiveRecord::Migration[8.1]
      def change
        ripple do
          create_ruleset :org_rules, version: 1
          create_shape   :person_shape
        end
      end
    end

Requirements:
  - Reversible. The block must record through ActiveRecord::Migration::CommandRecorder
    so \`db:rollback\` inverts what is inside it, with revert_to_version working
    exactly as it does today. This is the part that will be fiddly: the recorder
    is what \`change\` uses to invert, and a block with its own receiver has to
    keep participating in that. Write the revert spec FIRST.
  - The short names exist ONLY inside the block. Assert that
    \`create_shape\` is not defined on a bare migration — that assertion is the
    whole point of the design.
  - Update spec-corrections §4 from OPEN to settled, recording what was built.
  - Update README "Migrations" to show the block, and the coexistence spec to
    prove fx's create_function still works with this loaded.

Only the object kinds that EXIST in lib/ today get short names. Do not add
create_json_mapping, create_tenant or install_rule_library — they are not built,
and a name that raises NoMethodError inside a block that implies it works is
worse than no name.`,
  },
  {
    n: 4,
    title: 'FrameProbe',
    prompt: `${CONTEXT}

PHASE 4 — Establish how CONSTRUCT + JSON-LD framing actually behaves, before
any Ruby depends on it. README "Preloading" assumes a lot in three lines.

Against your own container, with a small fixture (a handful of people, some
managing others, some at an org — keep it tiny, the disk is tight):

  a. Confirm the real signature of \`sparql_construct_jsonld\` from pg_proc, plus
     \`jsonld_frame\`, \`export_jsonld_framed\` and \`jsonld_frame_to_sparql\`.
     The docs are stale; read the catalog.
  b. Run README "Preloading"'s exact CONSTRUCT with its exact frame. Dump the
     JSON verbatim. Does framing actually nest, or come back flat with @id
     references?
  c. The critical case for preloading: when a subject has MANY values for a
     framed property, is the result an array, or a single object that silently
     drops the rest? Test with one person managing three others. Then test the
     ONE-value case — does it come back as a bare object rather than a
     one-element array? That inconsistency is the classic JSON-LD trap and the
     hydrator must handle both.
  d. What happens to an OPTIONAL that did not match — key absent, null, or empty
     array?
  e. Are IRIs in the JSON-LD output bare, or angle-bracketed like the
     \`sparql()\` term strings? The hydrator joins on iri, so this decides
     whether it needs the same btrim treatment.
  f. Does the @context come back, and can a compact IRI in the frame be used
     without registering a prefix first?
  g. Rough cost: time the framed CONSTRUCT against N separate lateral joins for
     the same data at a realistic page size (20 subjects). If framing is not
     actually faster, that is a finding worth having before building on it.

Write docs/probe-jsonld-framing.md, one section per question with verbatim
output. If (b) shows framing does not nest, STOP and report — README
"Preloading" would need redesigning around plain CONSTRUCT, and that is a
decision, not an implementation detail.`,
  },
  {
    n: 5,
    title: 'Preload',
    prompt: `${CONTEXT}

PHASE 5 — Build \`graph_includes\`. README "Preloading".

    Person.where(role: "manager").graph_includes(:reports, :employer)

One CONSTRUCT shaped by a JSON-LD frame via \`pg_ripple.sparql_construct_jsonld\`,
one round trip, records hydrated by iri — following phase 4's findings exactly,
including the one-value-vs-array case and whether IRIs need btrim.

  - Build the CONSTRUCT and the frame from the graph_has_many/graph_has_one
    definitions already in lib/pg_ripple/associations.rb. Each association
    contributes its path and its target class.
  - Hydrate into the same association readers, so \`person.reports\` after
    graph_includes does NOT query again. That is the entire point — assert the
    query count, do not assert that it "works".
  - \`strict_loading\` (config, already in Configuration) raises on an
    un-preloaded graph association instead of lazily querying, matching
    ActiveRecord's own semantics and README "Preloading"'s last line.
  - Composes with ordinary \`includes\` and with the lateral-join relation from
    the slice.

A path association (\`+foaf.knows\`) cannot be framed the same way as a single
predicate — a frame nests properties, not path traversals. Work out what
graph_includes means for a path association and either support it honestly or
raise a clear error saying it is unsupported. Do not silently return wrong
results, and say in your report which you chose.`,
  },
  {
    n: 6,
    title: 'Specs',
    prompt: `${CONTEXT}

PHASE 6 — Specs for everything phases 2, 3 and 5 built.

The load-bearing ones, each an acceptance criterion:
  - Query COUNT, not just correctness: \`Person.where(...).graph_includes(:reports)\`
    then touching every record's reports must issue ONE graph query, and the
    same code without graph_includes must issue N. Use an
    ActiveSupport::Notifications subscriber on sql.active_record and assert the
    numbers. This is the only spec that actually proves preloading.
  - strict_loading raises on an un-preloaded graph association.
  - The \`ripple do … end\` block: short names work inside, are undefined
    outside, and db:rollback inverts them.
  - fx coexistence still passes with the block loaded.
  - The cache-invalidation fix: the reproduction from phase 1, now passing, and
    a host-app-shaped example using the exported helper.
  - Connection deprecation: with permanent_connection_checkout = :disallowed.

Run the full suite with the database. Report REAL counts, and separately report
the count without a database so the offline/online split stays honest.`,
  },
]

const REPORT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['files_written', 'decisions', 'blocked', 'verified'],
  properties: {
    files_written: { type: 'array', items: { type: 'string' } },
    decisions: { type: 'array', items: { type: 'string' } },
    blocked: { type: 'array', items: { type: 'string' } },
    verified: { type: 'string' },
  },
}

const requested = args?.phases
const selected = requested ? PHASES.filter((p) => requested.includes(p.n)) : PHASES

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

  // Both probes gate what follows them. A probe that ran nothing means the next
  // phase would be inventing behaviour rather than implementing it.
  if ((p.n === 1 || p.n === 4) && /^none$/i.test(report.verified.trim())) {
    log(`Phase ${p.n} ran nothing against a live database. Stopping — the next phase would be guessing.`)
    break
  }
}

// ── Review ───────────────────────────────────────────────────────────────────

if (Object.keys(reports).length === selected.length && selected.length > 1) {
  phase('Review')

  const LENSES = [
    {
      key: 'nplus1',
      prompt: `Review what was just built, adversarially.

Your lens: IS THE N+1 ACTUALLY GONE, and is the preloading correct?
  - Count queries yourself with an sql.active_record subscriber. Do not trust a
    spec that asserts "works" — assert the number.
  - Does a preloaded association return the SAME objects a lazy one would?
    Compare ids and ordering on a fixture where a person has three reports and
    another has none.
  - The one-value-vs-array JSON-LD trap: does a subject with exactly one report
    hydrate to a one-element collection, or to something else?
  - What happens on a subject with zero matches — empty collection, or nil?
  - Does graph_includes on a path association do something honest?
  - Is the CONSTRUCT built by binding, or is any value concatenated in?

Report what fails, with the numbers.`,
    },
    {
      key: 'connections',
      prompt: `Review what was just built, adversarially.

Your lens: CONNECTION AND TRANSACTION SAFETY.
  - Is the cache-invalidation fix the narrowest correct one, or does it paper
    over the problem? Read docs/probe-cache-invalidation.md and check the fix
    matches the diagnosis.
  - Does anything still call ActiveRecord::Base.connection? Prove it with
    permanent_connection_checkout = :disallowed, not with grep.
  - Does the repository hold a connection beyond a with_connection block?
  - Run the suite under a real connection pool with more than one thread. Any
    thread-local or memoised connection state that breaks?
  - The ripple do … end block: is it genuinely reversible? Run an actual
    db:migrate then db:rollback in the dummy app and check the database state,
    not the log output.
  - Does anything mixed into AbstractAdapter lack a ripple_ prefix, private
    methods included? That bug is silent and it breaks other people's gems.

Run things. Report what fails.`,
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
            evidence: { type: 'string', description: 'What was run and what it produced' },
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
  const serious = findings.filter((f) => f.severity !== 'low')
  log(`Review: ${findings.length} findings, ${serious.length} serious`)
  reports.Review = { findings }

  if (serious.length > 0) {
    phase('Report')
    reports.Fixes = await agent(
      `${CONTEXT}

Two reviewers checked what was just built. Their findings, with evidence:

${JSON.stringify(serious, null, 2)}

Reproduce each one YOURSELF before changing anything. Reviewers are wrong
sometimes, and a fix for a finding that was never true makes the code worse — if
you cannot reproduce it, mark it not_reproduced and change nothing.

Then run the full suite with and without a database, plus standardrb, and
reconcile README.md where the built behaviour legitimately differs from a spec
block — recording each such change in docs/spec-corrections.md. Never edit the
spec to match a bug; only where the spec was wrong.

Report the real command outcomes, failures included.`,
      { label: 'fix-and-reconcile', phase: 'Report', schema: REPORT_SCHEMA },
    )
  }
}

return {
  ran: Object.keys(reports),
  blocked: Object.entries(reports)
    .filter(([, r]) => Array.isArray(r.blocked))
    .flatMap(([title, r]) => r.blocked.map((b) => `${title}: ${b}`)),
  reports,
}

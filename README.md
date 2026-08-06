# pg_ripple-rails

Rails/ActiveRecord integration for [pg-ripple](https://github.com/trickle-labs/pg-ripple), a
knowledge-graph engine (RDF triple store, SPARQL 1.1, SHACL, Datalog reasoning) built as a
PostgreSQL 18 extension.

**The gem is not written yet.** This repo currently holds the design work:

- [`WORKFLOW.md`](WORKFLOW.md) — what the gem will manage, the design decisions and their
  reasons, the nine build phases, and the questions still open.
- [`docs/reference-gem-structure.md`](docs/reference-gem-structure.md) — a study of
  [`fx`](https://github.com/teoljungberg/fx) and
  [`pg_cron-rails`](https://github.com/n-at-han-k/pg_cron-rails), the two gems this one is
  modelled on, and which of their choices are load-bearing.
- [`.claude/workflows/build-pg-ripple-rails.js`](.claude/workflows/build-pg-ripple-rails.js) —
  the executable form of the plan.

## Setup

The reference checkouts are gitignored working material; recreate them with:

```sh
mkdir -p references && cd references
git clone https://github.com/n-at-han-k/pg_cron-rails.git
git clone https://github.com/teoljungberg/fx.git
git clone --depth 1 https://github.com/trickle-labs/pg-ripple.git
```

## What it will do

Teach the migration DSL, `db:rollback`, and `db/schema.rb` about the six pg_ripple objects that
are schema rather than data — named graphs, prefixes, SHACL shape sets, Datalog rule sets,
SPARQL views, and federation endpoints:

```ruby
class AddOrgChartRules < ActiveRecord::Migration[8.0]
  def change
    create_ripple_graph "https://example.org/org"
    create_ripple_prefix "ex", "https://example.org/"
    create_ripple_shapes :person, version: 1      # db/ripple/shapes/person_v01.ttl
    create_ripple_rules  :org_chart, version: 1   # db/ripple/rules/org_chart_v01.dl
    create_ripple_sparql_view :reports, version: 1 # db/ripple/views/reports_v01.rq
  end
end
```

Queries — `sparql()`, `validate()`, `infer()` — stay where they belong, on
`ActiveRecord::Base.connection`. See `WORKFLOW.md` section 1 for what is out of scope and why.

# pg_ripple-rails

Your ActiveRecord models, with a knowledge graph attached.

> **Status: design spec.** This gem does not exist. Every snippet below is a proposed
> API, paired with the SPARQL / SQL / Turtle it should emit. Read the output blocks as
> the acceptance criteria.
>
> Several output blocks have already been corrected against a live pg_ripple 0.128.0 —
> see [`docs/spec-corrections.md`](docs/spec-corrections.md) before implementing any
> section. The lateral-join SQL in [Graph associations](#graph-associations) and
> [Querying](#querying) is the one that changes shape.

```ruby
gem "pg_ripple-rails"
```

Requires PostgreSQL 18 with [`pg_ripple`](https://github.com/trickle-labs/pg-ripple).
`pg_trickle` optional (live views only).

## The shape of it

Models stay ActiveRecord. Tables stay tables. The graph is an additional index over the
same connection, in the same transaction, reached through a mixin.

```ruby
class Person < ApplicationRecord
  include PgRipple::Node

  belongs_to :account                                   # ordinary AR
  has_many   :memberships, dependent: :destroy          # ordinary AR

  graph type: RDF::Vocab::FOAF.Person do
    property :name,  predicate: RDF::Vocab::FOAF.name
    property :email, predicate: RDF::Vocab::FOAF.mbox
  end

  graph_has_many :network, path: +foaf.knows, class_name: "Person"
end
```

```ruby
alice.network.where(active: true).includes(:account).page(2)
```

`alice.network` is an `ActiveRecord::Relation`. Kaminari paginates it, Ransack searches
it, ActiveAdmin introspects it — because `Person` is a real ActiveRecord class and the
graph traversal arrives as a `JOIN LATERAL`.

There is [a second, model-free path](#graph-native-models) for data with no stable
relational shape. Start here.

## Contents

- [Install](#install)
- [Models](#models)
- [Property paths](#property-paths)
- [Graph associations](#graph-associations)
- [Preloading](#preloading)
- [Querying](#querying)
- [Validations](#validations)
- [Transactions](#transactions)
- [How writes work](#how-writes-work)
- [Migrations](#migrations)
- [Datalog rules](#datalog-rules)
- [Inference](#inference)
- [Explaining a fact](#explaining-a-fact)
- [What-if](#what-if)
- [Temporal](#temporal)
- [Multi-tenancy](#multi-tenancy)
- [Change notifications](#change-notifications)
- [Vector + graph search](#vector--graph-search)
- [Entity resolution](#entity-resolution)
- [Import and export](#import-and-export)
- [Background jobs](#background-jobs)
- [Graph-native models](#graph-native-models)
- [Escape hatches](#escape-hatches)
- [Testing](#testing)
- [Schema dumping](#schema-dumping)
- [Where the abstraction leaks](#where-the-abstraction-leaks)
- [Dependencies](#dependencies)

---

### Install

```
$ rails generate pg_ripple:install
      create  config/initializers/pg_ripple.rb
      create  db/migrate/20260806000000_install_pg_ripple.rb
      create  db/shapes/.keep
      create  db/rules/.keep
```

```ruby
class InstallPgRipple < ActiveRecord::Migration[8.1]
  def change
    enable_extension "pg_ripple"
  end
end
```

```ruby
# config/initializers/pg_ripple.rb
PgRipple.configure do |c|
  c.base_uri      = "https://app.example.com/"
  c.default_graph = nil            # nil = default graph
  c.validate      = :sync          # :sync | :async | :off
  c.strict_loading = Rails.env.local?
end
```

The repository binds to `ActiveRecord::Base.connection` — no second connection, no
second pool, no `database.yml` entry.

---

### Models

Give an existing table an `iri` column and mix in `PgRipple::Node`.

```ruby
class AddGraphToPeople < ActiveRecord::Migration[8.1]
  def change
    add_column :people, :iri, :string
    add_index  :people, :iri, unique: true
  end
end
```

```ruby
class Person < ApplicationRecord
  include PgRipple::Node

  graph type: RDF::Vocab::FOAF.Person, iri: ->(p) { "people/#{p.id}" } do
    property :name,      predicate: RDF::Vocab::FOAF.name,     from: :name
    property :email,     predicate: RDF::Vocab::FOAF.mbox,     from: :email, cast: RDF::URI
    property :birthdate, predicate: RDF::Vocab::FOAF.birthday, from: :born_on
    property :role,      predicate: EX.role                    # graph-only, no column
  end
end
```

`from:` mirrors an existing AR column into the graph. Omit it and the property lives
only in the graph, accessed the same way.

```ruby
alice = Person.create!(name: "Alice Ng", email: "alice@example.com")
alice.role = "engineer"
alice.save!

alice.iri           # => "https://app.example.com/people/1"
alice.rdf_subject   # => #<RDF::URI https://app.example.com/people/1>
alice.role          # => "engineer"    (read through the graph)
```

```turtle
<https://app.example.com/people/1> a foaf:Person ;
  foaf:name "Alice Ng" ;
  foaf:mbox <mailto:alice@example.com> ;
  ex:role "engineer" .
```

The `property` DSL is [ActiveTriples](https://github.com/ActiveTriples/ActiveTriples)'
`RDFSource`, so term coercion, `ActiveModel::Dirty` on graph attributes, and
`dump :ntriples` come from a library that has been doing this for a decade.

---

### Property paths

Ruby operators map onto SPARQL path syntax. `/` is sequence in both languages.

```ruby
foaf.knows                    # foaf:knows
foaf.knows / ex.worksAt       # foaf:knows/ex:worksAt
foaf.knows | ex.colleague     # foaf:knows|ex:colleague
+foaf.knows                   # foaf:knows+
foaf.knows.any                # foaf:knows*
foaf.knows.opt                # foaf:knows?
~ex.manages                   # ^ex:manages
!rdf.type                     # !(rdf:type)
```

A path is a value — build it at runtime, invert it, pass it around.

```ruby
path = ~ex.worksAt / ex.worksAt
path.inverse     # "^(^ex:worksAt/ex:worksAt)"
path.to_s        # "^ex:worksAt/ex:worksAt"
path.to_term     # #<RDF::URI> when the path is a single predicate
```

> **Corrected.** `#inverse` parenthesises what it inverts. SPARQL's
> `PathEltOrInverse ::= '^'? PathPrimary PathMod?` carries at most one `^`, so the
> flat `^^ex:manages` is a syntax error rather than a double inverse. See
> [`docs/spec-corrections.md` §14](docs/spec-corrections.md).

Paths are [StringBuilder](https://github.com/general-intelligence-systems/string_builder)
chains with a SPARQL-path concat handler. The chain is the data, the handler decides how
tokens become a path expression, and `#to_term` is the single seam back into RDF.rb:

```ruby
class PgRipple::Path < StringBuilder
  handler PgRipple::Handlers::SparqlPath
  def to_term = RDF::URI(to_s)
end
```

---

### Graph associations

`graph_has_many` and `graph_has_one` return `ActiveRecord::Relation`. There is no
foreign key, so direction is a property of the query: `belongs_to` is an inverse path.

```ruby
class Person < ApplicationRecord
  graph_has_many :friends,    predicate: foaf.knows,          class_name: "Person"
  graph_has_many :network,    path: +foaf.knows,              class_name: "Person"
  graph_has_many :reports,    path: +ex.manages,              class_name: "Person"
  graph_has_one  :manager,    path: ~ex.manages,              class_name: "Person"
  graph_has_many :colleagues, path: ~ex.worksAt / ex.worksAt, class_name: "Person"
end
```

```ruby
alice.network.where(active: true).order(:name).limit(20)
```
```sql
SELECT "people".* FROM "people"
JOIN LATERAL pg_ripple.sparql(
  'SELECT ?iri WHERE { <https://app.example.com/people/1> foaf:knows+ ?iri }'
) AS g(iri text) ON g.iri = "people"."iri"
WHERE "people"."active" = TRUE
ORDER BY "people"."name" ASC LIMIT 20
```

> **Corrected.** `pg_ripple.sparql()` returns `TABLE(result jsonb)` — one JSONB object
> per solution under a fixed column name — so a column definition list is not accepted
> and the real emitted SQL projects out of the JSONB. See
> [`docs/spec-corrections.md` §1](docs/spec-corrections.md). The Ruby API above is
> unaffected.

Writes go through the graph, reads come back as models:

```ruby
alice.friends << bob          # INSERT DATA { <alice> foaf:knows <bob> }
alice.friends.delete(bob)     # DELETE DATA { <alice> foaf:knows <bob> }
alice.friends.create!(name: "Bob")  # INSERT the row, then INSERT DATA the edge
alice.reports.pluck(:name)    # ordinary AR pluck
alice.network.count           # COUNT(*) over the lateral join
```

`#build` and `#new` raise. A graph edge is a triple between two subject IRIs and an
unsaved record has neither an IRI nor a foreign key to hold one, so there is nothing an
unsaved `build` could link — see
[`docs/spec-corrections.md` §14](docs/spec-corrections.md).

---

### Preloading

`graph_includes` compiles to one `CONSTRUCT` shaped by a JSON-LD frame, via
`pg_ripple.sparql_construct_jsonld()`.

```ruby
Person.where(role: "manager").graph_includes(:reports, :employer)
```
```sparql
CONSTRUCT { ?s ex:manages ?report ; ex:worksAt ?org }
WHERE     { ?s a foaf:Person ; ex:role "manager" .
            OPTIONAL { ?s ex:manages ?report }
            OPTIONAL { ?s ex:worksAt ?org } }
```
```json
{"@type": "foaf:Person", "ex:manages": {}, "ex:worksAt": {}}
```

One round trip, nested documents, records hydrated by `iri`. Without it, graph
associations are lazy and N+1 — the same rules as ActiveRecord. `strict_loading` raises
instead.

---

### Querying

Columns are ActiveRecord. Predicates go through `.graph`.

```ruby
Person.where(active: true)                  # SQL, unchanged
Person.graph.where(role: "engineer")        # SPARQL, returns AR::Relation
Person.where(active: true).graph.where(role: "engineer")   # both, one query
```

```sql
SELECT "people".* FROM "people"
JOIN LATERAL pg_ripple.sparql(
  'SELECT ?iri WHERE { ?iri a foaf:Person ; ex:role "engineer" }'
) AS g(iri text) ON g.iri = "people"."iri"
WHERE "people"."active" = TRUE
```

Graph predicates support the operators you'd expect:

```ruby
Person.graph.where(role: nil)              # FILTER NOT EXISTS { ?iri ex:role ?o }
Person.graph.where.not(role: "contractor")
Person.graph.where(age: 30..40)            # FILTER(?age >= 30 && ?age <= 40)
Person.graph.where(name: /^Al/)            # FILTER(REGEX(?name, "^Al"))
Person.graph.in_graph(hr_graph)
Person.graph.via(+ex.manages, from: alice)
```

Inspect before you run it:

```ruby
Person.graph.where(role: "engineer").to_sparql
Person.graph.where(role: "engineer").to_sql
Person.graph.where(role: "engineer").explain    # pg_ripple.explain_sparql()
```

`#limit` and `#offset` are the two methods `.graph` does not simply forward to the
relation. `pg_ripple.sparql()` builds every solution before PostgreSQL sees the first
one, so an outer bound truncates finished work — 40× on a 25 921-solution traversal. When
nothing downstream of the join can drop a row, the bound goes into the query instead, and
the query is ordered so that paging it is repeatable:

```ruby
Person.graph.where(role: "engineer").limit(20).offset(20).to_sparql
```
```sparql
PREFIX ex: <https://app.example.com/ns#>
SELECT DISTINCT ?iri
WHERE {
  ?iri a <http://xmlns.com/foaf/0.1/Person> .
  ?iri ex:role "engineer" .
}
ORDER BY ?iri
LIMIT 20
OFFSET 20
```

The `OFFSET` then comes *off* the SQL: the lateral has already skipped those solutions,
and applying it twice returns an empty page. Add a `WHERE` on a column, an `ORDER BY`, a
join or an `includes` and the bound stays in SQL, because any of those can drop a row the
truncated traversal was counting on. An association's `#limit` is never pushed down.

Large result sets stream through `pg_ripple.sparql_cursor()`, so peak memory is bounded
by `pg_ripple.export_batch_size` rather than the result set:

```ruby
Person.graph.where(active: true).find_each(batch_size: 500) { |p| puts p.name }
```

---

### Validations

Ordinary ActiveRecord validations, plus SHACL generated from them. ActiveModel runs in
Ruby for form feedback; SHACL runs in the database for every writer, including psql and
`COPY rdf FROM`.

```ruby
class Person < ApplicationRecord
  validates :name,  presence: true, length: { maximum: 100 }
  validates :email, presence: true, uniqueness: true
  validates :role,  inclusion: { in: %w[engineer manager designer] }
end
```

```
$ rails generate pg_ripple:shapes
      create  db/shapes/person_shape.ttl
      create  db/migrate/20260806000100_load_person_shape.rb
```

```turtle
# db/shapes/person_shape.ttl - GENERATED from Person. Edit the model, not this file.
<https://app.example.com/shapes/PersonShape> a sh:NodeShape ;
  sh:targetClass foaf:Person ;
  sh:property [ sh:path foaf:name ; sh:minCount 1 ; sh:maxCount 1 ; sh:maxLength 100 ] ;
  sh:property [ sh:path foaf:mbox ; sh:minCount 1 ; sh:nodeKind sh:IRI ] ;
  sh:property [ sh:path ex:role   ; sh:in ("engineer" "manager" "designer") ] .
```

| ActiveModel | SHACL |
|---|---|
| `presence: true` | `sh:minCount 1` |
| `length: { maximum: n }` | `sh:maxLength n` |
| `numericality: { greater_than: n }` | `sh:minExclusive n` |
| `inclusion: { in: [...] }` | `sh:in` |
| `format: { with: /re/ }` | `sh:pattern` |
| `uniqueness: true` | `sh:SPARQLConstraint` |

Database-side violations land on `errors`, keyed by attribute:

```ruby
person = Person.new(role: "chef")
person.valid?                    # => false
person.errors.full_messages      # => ["Role is not included in the list"]
person.save(validate: :async)    # background check; report table
Person.shacl_report              # all violations for this class
```

`presence` becomes `sh:minCount 1`, which means "must be stated" — weaker than
`NOT NULL`, because RDF is open-world.

> **Constraint found by probe.** `load_shacl` keeps only a parsed projection of the
> shape: `sh:severity`, `sh:name`, `sh:description` and `sh:order` are dropped on the
> way in, and the Turtle is not recoverable. The generated `.ttl` file is therefore the
> only source of truth. See [Schema dumping](#schema-dumping).

---

### Transactions

One connection, so this is free. Rows and triples commit or roll back together.

```ruby
ActiveRecord::Base.transaction do
  account = Account.create!(name: "Acme")
  alice   = Person.create!(account:, name: "Alice Ng", role: "engineer")
  alice.friends << Person.find_by(name: "Bob")
  raise ActiveRecord::Rollback if over_quota?(account)
end
```

Nothing is written — not the row, not the triples, not the derived facts. Isolation is
PostgreSQL's, not simulated. Verified empirically: a `BEGIN`/`ROLLBACK` covering every
create and drop in this README restores the baseline exactly, including pg_trickle
stream tables ([`docs/probe-results.md` §c](docs/probe-results.md)).

---

### How writes work

`PgRipple::Node` installs a diff-based persistence strategy rather than ActiveTriples'
default whole-object write.

```ruby
alice.role = "manager"
alice.save!
```
```sparql
DELETE DATA { <https://app.example.com/people/1> ex:role "engineer" } ;
INSERT DATA { <https://app.example.com/people/1> ex:role "manager" }
```

Not:

```sparql
DELETE WHERE { <https://app.example.com/people/1> ?p ?o } ;
INSERT DATA  { ...every triple, including the unchanged ones... }
```

This matters for three reasons: unchanged triples don't churn between the delta and main
partitions, CDC subscribers see only real changes, and DRed doesn't retract-then-rederive
inference for facts that never moved. Override per model if you need the default:

```ruby
class LegacyThing < ApplicationRecord
  include PgRipple::Node
  graph persistence_strategy: ActiveTriples::RepositoryStrategy
end
```

Destroys remove inbound edges too, which ActiveTriples does not do by default:

```ruby
class Person < ApplicationRecord
  graph dependent: :nullify_references    # also DELETE WHERE { ?s ?p <iri> }
end
```

---

### Migrations

Rulesets, shapes and mappings are schema. They live in files and load in migrations.

```
db/rules/org_rules_v01.dlog.rb
db/shapes/person_shape.ttl
db/mappings/person_mapping.jsonld
```

```ruby
class AddOrgRules < ActiveRecord::Migration[8.1]
  def change
    create_ruleset      :org_rules, version: 1
    create_shape        :person_shape
    create_json_mapping :person, shape: "https://app.example.com/shapes/PersonShape"
    create_tenant       :acme, quota: 5_000_000
    install_rule_library "https://rules.example.com/finance/v2.ttl"
  end
end
```

```ruby
class UpgradeOrgRules < ActiveRecord::Migration[8.1]
  def change
    update_ruleset :org_rules, version: 2, revert_to_version: 1
  end
end
```

`create_ruleset` calls `pg_ripple.validate_rule()` before `load_rules()`, so an unbound
head variable or a stratification cycle fails `db:migrate` rather than production.

> **Naming.** The migration layer that already exists in `lib/` uses `create_ripple_*`
> names, because every method mixed into `AbstractAdapter` must be prefixed or it
> shadows `fx`'s same-named methods for the whole host application — see
> [`docs/reference-gem-structure.md`](docs/reference-gem-structure.md). Reconciling
> those two naming schemes is an open decision:
> [`docs/spec-corrections.md` §4](docs/spec-corrections.md).

---

### Datalog rules

Horn clauses as Ruby. `<=` is the neck, `&` is conjunction.

```ruby
# db/rules/org_rules_v01.dlog.rb
Rules.build(:org_rules) {
  ex.indirect_manager[x, z] <= ex.manager[x, z]
  ex.indirect_manager[x, z] <= ex.manager[x, y] & ex.indirect_manager[y, z]

  ex.senior[x] <= ex.manages[x, y] & ex.manages[y, z]

  weight(0.8) { ex.likely_duplicate[x, y] <= ex.same_email[x, y] }
}
```
```
?x ex:indirectManager ?z :- ?x ex:manager ?z .
?x ex:indirectManager ?z :- ?x ex:manager ?y, ?y ex:indirectManager ?z .
?x ex:senior true :- ?x ex:manages ?y, ?y ex:manages ?z .
@weight(0.8) ?x ex:likelyDuplicate ?y :- ?x ex:sameEmail ?y .
```

Temporal filters and built-ins:

```ruby
Rules.build(:audit) {
  ex.superseded[x, y] <= ex.version_of[x, y] & after(x[:created], y[:created])
  ex.similar[x, y]    <= pg.jaro_winkler(x[:name], y[:name]) > 0.9
}
```

Static analysis before the round trip:

```ruby
Rules.build(:org_rules).validate!
# => PgRipple::UnboundHeadVariable: ?z appears in head but no body atom
```

`Rules.build` is a StringBuilder handler. There is no Datalog builder anywhere in the
Ruby ecosystem, so this is the one place the gem emits a language from scratch rather
than delegating to `sparql` — and a token buffer is enough, because a Horn clause is
linear. The same applies to the Turtle emitted by
[`pg_ripple:shapes`](#validations) and to the `pg_ripple_http` route helpers:

| Handler | Emits | Used by |
|---|---|---|
| `Handlers::SparqlPath` | `^ex:worksAt/ex:worksAt` | `graph_has_many path:` |
| `Handlers::Datalog` | `?x ex:m ?z :- ?x ex:n ?z .` | `Rules.build` |
| `Handlers::Turtle` | `sh:path foaf:name ; sh:minCount 1` | shape generator |
| `Handlers::Route` | `/temporal/graphs/{iri}/diff` | `PgRipple.http_client` |

Leaf tokens delegate to `RDF::Literal#to_base` rather than `#to_s`, so datatypes,
language tags and quote escaping are handled by code that has been through the W3C test
suite. SPARQL has five token kinds where SQL has two; a naive concat handler gets this
wrong.

> **Corrected.** The real `load_rules` signature is `load_rules(rules, rule_set)` — the
> program comes first, and the emitted body separator is `,` with every rule ending in
> ` .`. The stale upstream docs have the arguments reversed, which binds a rule-set name
> as a Datalog program. See [`docs/probe-results.md` §0](docs/probe-results.md).

---

### Inference

```ruby
PgRipple.load_builtin(:rdfs)
PgRipple.infer(:rdfs)
PgRipple.infer(:org_rules, mode: :goal, goal: [alice, ex.indirect_manager, :?])
PgRipple.infer(:org_rules, mode: :demand)
PgRipple.infer(:org_rules, mode: :wfs)
```

Derived facts are ordinary associations:

```ruby
class Person < ApplicationRecord
  graph_has_many :indirect_reports, path: ex.indirectManager,
                                    class_name: "Person", derived: :org_rules
end

alice.indirect_reports.where(active: true)
alice.indirect_reports.derived?      # => true
```

Conflicts:

```ruby
PgRipple.rule_conflicts(:org_rules, mode: :static)
# => [{ rules: [3, 7], reason: "same head, opposing values" }]
```

---

### Explaining a fact

```ruby
PgRipple.justify(alice, ex.indirectManager, carol)
```
```
ex:indirectManager(alice, carol)
├─ rule 2: ?x ex:indirectManager ?z :- ?x ex:manager ?y, ?y ex:indirectManager ?z
│  ├─ ex:manager(alice, bob)                      [asserted]
│  └─ ex:indirectManager(bob, carol)
│     └─ rule 1: ?x ex:indirectManager ?z :- ?x ex:manager ?z
│        └─ ex:manager(bob, carol)                [asserted]
```

```ruby
PgRipple.explain(alice, ex.indirectManager, carol)
# => "Alice indirectly manages Carol because Alice manages Bob, and Bob manages Carol."

PgRipple.explain(*fact, format: :jsonb)   # tree + narrative, for API consumers
```

Requires `pg_ripple.record_derivations`. Cached with a TTL;
`PgRipple.vacuum_explanations`.

---

### What-if

Speculative inference in a sub-transaction. Nothing is written.

```ruby
PgRipple.hypothetically do |h|
  h.assert [dave.rdf_subject, ex.manages, alice.rdf_subject]
  h.derived    # => [[dave, ex.indirectManager, bob], [dave, ex.indirectManager, carol]]
  h.retracted  # => []
end
```

---

### Temporal

```ruby
class Person < ApplicationRecord
  graph temporal: %i[role salary_band]        # mark_temporal()
end
```

```ruby
Person.as_of(6.months.ago).graph.where(role: "engineer")   # point_in_time()
alice.role_at(1.year.ago)                                  # => "designer"
alice.history(:role)
# => [{ value: "designer", from: 2024-01-01, to: 2025-06-01 },
#     { value: "engineer", from: 2025-06-01, to: nil }]
```

```ruby
snapshot = PgRipple.graph_at(hr_graph, 1.month.ago)
Person.graph.in_graph(snapshot).count

PgRipple.graph_diff(hr_graph, 1.month.ago, Time.current)
# => [{ change: "added",   statement: [...] },
#     { change: "removed", statement: [...] }]
```

---

### Multi-tenancy

Every generated query is rewritten to a `GRAPH` clause before it reaches Postgres — AST
rewriting via the `sparql` gem, not string interpolation.

```ruby
PgRipple.with_tenant(current_account) do
  Person.graph.where(role: "engineer")
end
```
```sparql
SELECT ?iri WHERE {
  GRAPH <https://app.example.com/tenants/acme> {
    ?iri a foaf:Person ; ex:role "engineer" .
  }
}
```

User-supplied SPARQL gets scoped and stripped the same way:

```ruby
PgRipple.sanitize(params[:query], tenant: current_account, max_limit: 1000)
# raises PgRipple::ForbiddenOperator if the query contains SERVICE
```

```ruby
current_account.graph_stats   # => { triples: 412_339, quota: 5_000_000 }
```

---

### Change notifications

`create_subscription()` fires `pg_notify`; the listener republishes as
`ActiveSupport::Notifications` and, optionally, ActionCable.

```ruby
class Person < ApplicationRecord
  graph notifies_on_change: "?s a foaf:Person ; ex:role ?role"
end
```

```ruby
ActiveSupport::Notifications.subscribe("triple_change.pg_ripple") do |*, payload|
  Rails.logger.info payload[:statement]
end
```

```ruby
class GraphChannel < ApplicationCable::Channel
  def subscribed
    stream_from PgRipple.subscription("SELECT ?s WHERE { ?s ex:status ex:Alert }")
  end
end
```

The listener holds a dedicated connection outside the pool — a `LISTEN`ing connection
cannot be checked back in.

---

### Vector + graph search

```ruby
class Document < ApplicationRecord
  include PgRipple::Node
  has_neighbors :embedding                          # neighbor gem, unchanged

  graph type: EX.Paper do
    property :title, predicate: RDF::Vocab::DC.title, from: :title
  end
end
```

```ruby
Document.nearest_neighbors(:embedding, query_vec, distance: "cosine")
        .where(published: true)
        .graph.via(~ex.authored / +ex.coAuthor, from: alice)
        .limit(20)
```
```sparql
SELECT ?iri ?score WHERE {
  <https://app.example.com/people/1> ^ex:authored/ex:coAuthor+ ?author .
  ?author ex:authored ?iri .
  BIND(pg:similar(?iri, "graph neural networks") AS ?score)
  FILTER(?score > 0.75)
} ORDER BY DESC(?score)
```

RAG context, ready for a prompt:

```ruby
PgRipple.rag_retrieve(
  query:          "Who manages the Oslo team?",
  graph_patterns: [ex.locatedIn => EX.Oslo, ex.role => :?role],
  top_k:          10
)
# => { "@context" => {...}, "@graph" => [...] }
```

---

### Entity resolution

```ruby
result = PgRipple.resolve_entities(
  source:   crm_graph,
  target:   billing_graph,
  blocking: :email,
  dry_run:  true
)

result.candidates         # => 1_204
result.accepted           # => 987
result.rejected_by_shacl  # => 12
result.commit!            # writes owl:sameAs + RDF-star provenance
```

Privacy-preserving matching, no raw PII on the wire:

```ruby
clk = PgRipple.bloom_encode("alice ng", key: Rails.application.secret_key_base)
PgRipple.dice_similarity(clk, other_clk)          # => 0.91
```

```ruby
PgRipple.evaluate_resolution(gold_graph:)
# => { precision: 0.94, recall: 0.88, f1: 0.91, b3: {...} }
```

---

### Import and export

```ruby
PgRipple.load(file: "db/seeds/people.ttl", graph: hr_graph)
PgRipple.load(url: "https://example.org/data.nt")
PgRipple.load(io: params[:file], format: :jsonld)
PgRipple.bulk_load("db/seeds/large.nt")           # COPY rdf FROM
PgRipple.r2rml_load(Rails.root.join("db/mappings/legacy.ttl"))
```

```ruby
Person.graph.where(active: true).to_turtle
Person.graph.where(active: true).to_jsonld(frame: { "@type" => "foaf:Person" })
alice.to_jsonld                                   # export_jsonld_node()
alice.dump :ntriples                              # ActiveTriples
```

```ruby
PgRipple.ingest_json(:person, request.raw_post)
PgRipple.export_json(:person, alice.rdf_subject)
```

---

### Background jobs

```ruby
PgRipple::InferJob.perform_later(:org_rules)
PgRipple::PageRankJob.perform_later(graph: hr_graph, damping: 0.85)
PgRipple::ResolveEntitiesJob.perform_later(source:, target:)
PgRipple::ValidateJob.perform_later(shape: "PersonShape")
PgRipple::TrainEmbeddingsJob.perform_later(model: :rotate)
```

Analytics land back on relations:

```ruby
Person.order_by_pagerank.limit(10)
Person.centrality(:betweenness).limit(10)
PgRipple.explain_pagerank(alice.rdf_subject)
```

---

### Graph-native models

For data with no stable relational shape — imported ontologies, federated data, anything
where "what columns does this have" has no answer. No table, no `id`, ActiveModel only.

```ruby
class Concept < PgRipple::Base
  configure type: RDF::Vocab::SKOS.Concept, base_uri: "https://app.example.com/concepts/"

  property :pref_label, predicate: RDF::Vocab::SKOS.prefLabel
  property :definition, predicate: RDF::Vocab::SKOS.definition

  has_many :narrower, path: +RDF::Vocab::SKOS.narrower, class_name: "Concept"
end
```

```ruby
Concept.for("https://app.example.com/concepts/rdf")
Concept.query.where(pref_label: "RDF").limit(10)     # PgRipple::Query, not AR::Relation
```

`PgRipple::Query` is lazy and compiles to one SPARQL query, but it is **not** an
`ActiveRecord::Relation` — Kaminari, Ransack and ActiveAdmin will not accept it without
a shim. That is the cost of leaving the table behind, and the reason this section is at
the bottom.

> Naming: `ActiveTriples::Relation` is the set of values for one predicate on one
> resource — what `alice.name` returns. It is unrelated to `PgRipple::Query`. The gem
> never uses the word Relation for a query object.

---

### Escape hatches

```ruby
PgRipple.select(<<~SPARQL)
  SELECT ?s ?name WHERE { ?s foaf:knows+ ?friend ; foaf:name ?name }
SPARQL
# => [#<RDF::Query::Solution s=... name=...>, ...]

Person.find_by_sparql("SELECT ?iri WHERE { ?iri ex:role 'engineer' }")
# => AR::Relation
```

The repository is a plain `RDF::Repository`, so the ruby-rdf ecosystem applies:

```ruby
repo = PgRipple.repository
repo << [alice.rdf_subject, foaf.knows, bob.rdf_subject]
repo.query([nil, foaf.name, nil]).each { |st| puts st }
repo.count
```

Do **not** wrap it in `SPARQL::Client.new(repo)` — that evaluates the algebra in pure
Ruby, one `query_pattern` call at a time, bypassing the extension entirely. The
repository implements `query_execute` so whole queries go to Postgres.

For the HTTP service instead of the in-process path:

```ruby
PgRipple.http_client.select.where([:s, :p, :o]).limit(10)
```

---

### Testing

```ruby
# spec/rails_helper.rb
require "pg_ripple/rspec"

RSpec.configure do |c|
  c.include PgRipple::TestHelpers

  # Required under use_transactional_tests. See below.
  c.before(:each) { PgRipple::TestHelpers.reset_dictionary_cache! }
end
```

Triples roll back with the transactional fixture — same connection, so there is no store
to truncate.

> **Corrected: there is one thing to clean up, and it is not the data.** A rolled-back
> transaction poisons pg_ripple 0.128.0's per-backend dictionary cache. The cache maps
> terms to dictionary ids; `ROLLBACK` removes the dictionary rows and leaves the cache
> holding their ids, so the *next* example on that connection writes triples against ids
> that no longer exist and every query for those terms returns nothing — silently, and
> only for the terms the rolled-back example was the first to use, which is what makes it
> look like a flaky test. Three rolled-back rounds of insert-then-query on one connection
> return 1, 0, 0; with a reconnect between them, 1, 1, 1. `reset_dictionary_cache!` drops
> the pool's connections, which is the only way to clear it. See
> [`docs/spec-corrections.md` §11](docs/spec-corrections.md).

Two smaller things about the examples below. `raise ActiveRecord::Rollback` needs
`transaction(requires_new: true)` inside a transactional suite, or Rails swallows it and
rolls nothing back — that is the Rails rule the "Transactions" section nine sections up
does not have to worry about. And `change_triples` counts the writes on the wire, through
an `ActiveSupport::Notifications` event, rather than diffing the store before and after:
a whole-object rewrite and a minimal diff leave the store in identical states, so a
before/after count could not tell apart the one thing this example exists to test.

```ruby
it "derives the management chain" do
  load_rules :org_rules
  alice = create(:person)
  bob   = create(:person, manager: alice)

  PgRipple.infer(:org_rules)

  expect(alice.reports).to include(bob)
  expect(fact(alice, ex.indirectManager, bob)).to be_derived
end

it "rejects an invalid role" do
  expect(build(:person, role: "chef")).to violate_shape("PersonShape", path: ex.role)
end

it "writes only what changed" do
  alice = create(:person, role: "engineer")
  expect { alice.update!(role: "manager") }.to change_triples(by: 1)
end
```

Matchers: `have_triple`, `be_derived`, `violate_shape`, `entail`, `change_triples`.

---

### Schema dumping

`pg_ripple` lives in its own schemas, so `schema.rb` cannot see it. The gem registers a
dumper that emits rulesets, shapes and mappings alongside tables, keeping
`db:schema:load` correct in CI.

```ruby
# db/schema.rb
enable_extension "pg_ripple"

create_ruleset      "org_rules", version: 2
create_shape        "person_shape"
create_json_mapping "person",    shape: "https://app.example.com/shapes/PersonShape"
create_tenant       "acme",      quota: 5000000

create_table "people", force: :cascade do |t|
  t.string "iri", null: false
  t.index ["iri"], unique: true
end
```

Set `config.active_record.schema_format = :sql` if you prefer `structure.sql`.

Dumping a **file reference** rather than the object's content is what makes this work at
all for shapes: the catalog keeps only a lossy parse, so there is nothing faithful to
quote back. Rulesets and views could be dumped verbatim, but are dumped by reference too,
for consistency and so a rollback has a version to return to.

---

### Where the abstraction leaks

Semantic differences, not bugs. Read before shipping.

**Graph properties are multi-valued.** `person.role` returns a scalar only because
`sh:maxCount 1` says so. Underneath it is a set. `person.role_values` returns the array.

**Presence is not `NOT NULL`.** RDF is open-world. `sh:minCount 1` means "must be
stated here", which is weaker than "cannot be null".

**`graph_has_many` has no foreign key.** Nothing prevents an edge to a deleted subject.
`dependent: :nullify_references` sweeps inbound edges on destroy; without it they dangle,
which is defensible RDF semantics but surprising from ActiveRecord.

**Typos raise, unlike raw SPARQL.** `Person.graph.where(rle: "x")` would silently return
zero rows against a schemaless store. The gem raises `PgRipple::UnknownProperty` because
the schema lives in Ruby.

**Two SPARQL parsers are in play.** `SPARQL::Grammar` (Ruby) validates and rewrites;
spargebra (Rust) executes. They will disagree at the edges — RDF-star, SPARQL 1.2,
`pg:` extension functions — so Ruby-side validation is advisory and fails open.
Postgres is the authority.

**Graph joins are lateral, so cardinality is yours to manage.** A path with high fan-out
(`+foaf.knows` on a dense graph) will produce a large intermediate before the `WHERE`
filters it. Use `explain` and bound the path depth.

**Named graphs are not schema.** `create_graph` interns an IRI and creates no catalog
row; `list_graphs()` derives its answer from the triples present, so an empty graph is
invisible and a seeded one appears undeclared. Graphs cannot be migrated or dumped —
they are a seed-data concern. See
[`docs/probe-results.md` §3](docs/probe-results.md).

---

### Dependencies

```ruby
spec.add_dependency "rails",          ">= 7.1"
spec.add_dependency "rdf",            "~> 3.3"   # terms, Repository, readers/writers
spec.add_dependency "active-triples", "~> 1.2"   # RDFSource + property DSL
spec.add_dependency "sparql",         "~> 3.3"   # parse, rewrite, validate
spec.add_dependency "string_builder", "~> 1.0"   # paths, Datalog, Turtle, routes
spec.add_dependency "pg",             "~> 1.5"
```

Deliberately not depended on:

- **sparql-client** — its `RDF::Queryable` mode evaluates in Ruby. Available as a soft
  dependency for the HTTP endpoint only.
- **spira** — same job as ActiveTriples, but a base class rather than a mixin, so it
  cannot compose with `ApplicationRecord`.

The division of labour between `string_builder` and `sparql` is deliberate:
StringBuilder handles the **write side**, where the gem emits a language (paths, Datalog,
Turtle, routes) and 113 lines of concat handler beats a parser. `sparql` handles the
**read side**, where the gem needs to analyse a query tree — `Grammar.valid?` at
migration time, `Operator#rewrite` for tenant scoping and SERVICE stripping,
`#variables` for the `AS t(cols)` projection list. Those are operations over a parsed
AST, not formatting, and a token buffer cannot do them.

Basic graph patterns stay with `sparql-client` rather than StringBuilder: a BGP is a
join graph, not a chain, and a linear token buffer has no way to express that `?x` is the
same node across two sibling patterns.

On ActiveTriples specifically: the surface used here is four modules (`RDFSource`,
`Properties`, `Configurable`, `PersistenceStrategy`), the persistence strategy is
replaced, and the DSL is wrapped behind `PgRipple::Node`. Upstream activity is low —
Samvera's Hyrax 5 moved to Valkyrie and deprecated ActiveFedora, from which ActiveTriples
was extracted — so the integration is kept narrow enough to vendor if that becomes
necessary.

### License

Apache 2.0, matching pg_ripple.

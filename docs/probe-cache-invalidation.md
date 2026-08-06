# Probe: what a rolled-back transaction actually poisons

Phase 1 diagnosis. **Nothing is fixed here** — this document establishes the mechanism and
recommends the narrowest correct fix.

Everything below was measured against a container this phase created and destroyed:
`ghcr.io/trickle-labs/pg-ripple:0.128.0`, PostgreSQL 18.4, `shared_preload_libraries =
pg_ripple,pg_trickle`, `pg_ripple` extension version `0.128.0`. All output is verbatim.

**Headline: the cache is not the dictionary, and the fix is not `disconnect!`.**
[`spec-corrections.md` §11](spec-corrections.md) and `PgRipple::TestHelpers`
both name the *dictionary* cache. The observations in §11 are all reproducible, but the
diagnosis is wrong. The dictionary caches are cleared correctly on abort — that is what
`XACT_EVENT_ABORT` → `dictionary::clear_caches()` is for, and it works. What is not cleared
is the **SPARQL→SQL plan cache**, which stores generated SQL with dictionary ids baked in
as integer literals.

Two separate defects came out of this probe, both in the extension:

| | trigger | what survives | blast radius | cleared by |
| --- | --- | --- | --- | --- |
| **A** | top-level transaction **abort** (`ROLLBACK` *or* a failed statement) | per-backend SPARQL plan cache holding SQL with dead dictionary ids | reads return **zero rows**, silently, for that query on that backend, forever | `pg_ripple.plan_cache_reset()`; a new backend |
| **B** | `ROLLBACK TO SAVEPOINT` | **shared-memory** encode cache holding dead term→id mappings | triples **written** against ids with no dictionary row; bindings decode to `null`; **commits permanently corrupt data** | `pg_ripple.flush_encode_cache()`; a top-level `ROLLBACK` |

Defect A is the one the Rails reviewer found. Defect B was found on the way and is worse:
it is not a test-harness problem, it survives a reconnect, and it corrupts the store.

---

## a. Minimal reproduction, SQL only — no ActiveRecord

Three rounds of insert-then-read, each in its own transaction, each rolled back, all on one
`psql` session:

```sql
BEGIN;
SELECT pg_ripple.insert_triple('<https://example.org/alice>','<https://example.org/knows>','<https://example.org/bob>','');
SELECT count(*) FROM pg_ripple.sparql('SELECT ?o WHERE { <https://example.org/alice> <https://example.org/knows> ?o }');
ROLLBACK;
-- ×3, identical
```

```
=== ROUND 1 ===
 insert_triple
---------------
             1
 count
-------
     1
=== ROUND 2 ===
 insert_triple
---------------
             2
 count
-------
     0
=== ROUND 3 ===
 insert_triple
---------------
             3
 count
-------
     0
```

1, 0, 0 — the same numbers §11 reports, with no Ruby, no ActiveRecord, no connection pool in
the picture. **This is the extension's, not ours.**

---

## b. What is cached: the plan cache, holding dictionary ids as SQL literals

Three probes, one session, no reset between them except where stated.

```sql
-- R2: same query text, but pg_ripple.plan_cache_reset() first
-- R3: DIFFERENT variable name (?zzz), so a different plan-cache key, no reset
-- R4: same query text again, no reset (control)
```

```
=== R1: warm ===                                   count = 1
=== R2: same query text, after plan_cache_reset() === count = 1
=== R3: DIFFERENT variable name, no reset ===       count = 1
=== R4: same query text again, no reset (control) === count = 0
```

Resetting the plan cache fixes it. Changing the query so it lands in a different cache slot
fixes it. Changing nothing reproduces it. That is the plan cache and nothing else.

The mechanism, made explicit — dictionary ids and the cached SQL, side by side:

```
=== R1 ===
 id |           value
----+---------------------------
 38 | https://example.org/alice
 39 | https://example.org/knows
 40 | https://example.org/bob
 count = 1
 hits | misses | evictions | hit_rate
    0 |      1 |         0 |        0
ROLLBACK
=== R2 ===
 id |           value
----+---------------------------
 42 | https://example.org/alice
 43 | https://example.org/knows
 44 | https://example.org/bob
 count = 0
 hits | misses | evictions | hit_rate
    1 |      1 |         0 |      0.5
 rows_under_r1_ids
                 0
 rows_under_r2_ids
                 1
```

R2 is a **plan-cache hit** (`hits` goes 0 → 1). The dictionary handed out *new* ids
(42/43/44) because the encode caches *were* correctly cleared on abort — that is the proof
that the dictionary cache is not the culprit. The triple really is in the store under the
new ids (`rows_under_r2_ids = 1`). The cached plan looks for the old ones
(`rows_under_r1_ids = 0`) and finds nothing.

The generated SQL, from `pg_ripple.explain_sparql(…, 'sql')` in each round:

```
R1: SELECT _t0.o AS _v_o FROM (SELECT s, o, g FROM _pg_ripple.vp_rare WHERE p = 31) AS _t0 WHERE _t0.s = 30
R2: SELECT _t0.o AS _v_o FROM (SELECT s, o, g FROM _pg_ripple.vp_rare WHERE p = 35) AS _t0 WHERE _t0.s = 34
```

`p = 31`, `s = 30` are dictionary ids, frozen into the cached string. In `references/pg-ripple`:

- `src/sparql/sqlgen.rs:370` and `src/sparql/plan.rs:119` call `dictionary::encode(...)`
  during **SQL generation**, so every IRI/literal constant in the query becomes an integer
  literal in the generated SQL.
- `src/sparql/plan_cache.rs` caches that string in a `thread_local!` LRU. The key
  (`cache_key_inner`, line 143) is a digest of the query *algebra* plus GUCs, the role oid
  and `schema_generation` — **no dictionary generation, no transaction id**.
- `src/lib.rs:534` `xact_callback_c` calls `dictionary::clear_caches()` on
  `XACT_EVENT_ABORT`, and `src/storage/mutation_journal::clear()`. It does **not** call
  `plan_cache::reset()` (`src/sparql/plan_cache.rs:118`), which exists and is exposed as
  `pg_ripple.plan_cache_reset()`.

Ruled out by measurement, not by reading:

| suspect | probe | result |
| --- | --- | --- |
| dictionary encode/decode LRU | ids change across rounds (38→42) | correctly cleared |
| shared-memory encode cache | same | correctly evicted on top-level abort |
| `_pg_ripple.dictionary_hot` | n/a — a table, rolls back with everything else | not involved |
| `_pg_ripple.predicates` / VP-table registry | `pg_ripple.invalidate_catalog_cache()` | no effect (see §c) |
| plan cache | `pg_ripple.plan_cache_reset()` | **fixes it** |

A query with no IRI/literal constants bakes in no ids and is immune:

```
=== e3: all-variable query across rolled-back rounds ===
 warm_allvar             4
 allvar_after_rollback   4
```

And the store itself is fine — an `ASK` over the same triple (a different cache slot)
answers `t` in the very transaction where the poisoned `SELECT` answers 0:

```
 ask_fresh_form        | t
 select_poisoned_form  | 0
```

---

## c. Lifetime: per backend, for the life of the session

```
same session, round 2                 : 0
new connection, same terms, round 3   : 1
```

Session-lifetime, per backend, exactly as `thread_local!` implies.

What clears it, measured one call at a time against a poisoned session:

```
--- c1: DISCARD ALL then retry             --- after_discard_all        = 0
--- c2: pg_ripple.flush_encode_cache()     --- after_flush_encode       = 0
--- c3: pg_ripple.invalidate_catalog_cache() --- after_invalidate_catalog = 0
--- c4: pg_ripple.plan_cache_reset()       --- after_plan_cache_reset   = 1
```

- `DISCARD ALL` does **not** clear it — the cache is extension-private Rust state, invisible
  to PostgreSQL's own reset machinery.
- `flush_encode_cache()` and `invalidate_catalog_cache()` do not clear it, which is further
  confirmation that neither the dictionary nor the predicate/VP registry is the cache in
  question.
- `prewarm_dictionary_hot()` is irrelevant: it repopulates a table, not this cache.
- `plan_cache_reset()` clears it, and is sufficient on its own — three rolled-back rounds on
  **one** connection with a reset before each:

```
=== three rolled-back rounds on ONE connection, plan_cache_reset() before each ===
 round1  1
 round2  1
 round3  1
```

There is no GUC escape. `pg_ripple.plan_cache_size` is documented as “0 = disabled”, and it
is not: `PLAN_CACHE_SIZE` is read only by `src/sparql/explain.rs:120` for reporting and never
gates a lookup.

```
SET pg_ripple.plan_cache_size = 0;
 pg_ripple.plan_cache_size | 0
 warm                      | 1
 round2_with_cache_size_0   | 0
```

`pg_ripple.plan_cache_capacity` is read once when the `thread_local!` is initialised, so
setting it mid-session does nothing either, and its range (64–65536) excludes 0.

---

## d. It is transaction *abort*, not the `ROLLBACK` keyword — and savepoints are a different bug

An aborted statement is enough. No `ROLLBACK` was issued by the client; `SELECT 1/0` aborted
the transaction and psql sent the implicit rollback:

```
=== d2: aborted STATEMENT ===
 warm                   1
ERROR:  division by zero
 after_statement_abort  0
```

A committed transaction never poisons:

```
=== d3: control — COMMIT instead of ROLLBACK ===
 warm          1
 after_commit  1
```

So the trigger is `XACT_EVENT_ABORT` — any exception on the connection, any deadlock retry,
any constraint violation, not only a deliberate rollback.

### Defect B: `ROLLBACK TO SAVEPOINT` corrupts the store instead

Brand-new terms, fresh session, one top-level transaction, savepoint rolled back and the
same triple re-inserted:

```sql
BEGIN;
  SAVEPOINT sp1;
    SELECT pg_ripple.insert_triple('<https://example.org/s8>','<https://example.org/p8>','<https://example.org/o8>','');
    SELECT * FROM pg_ripple.sparql('SELECT ?o WHERE { <https://example.org/s8> <https://example.org/p8> ?o }');
  ROLLBACK TO SAVEPOINT sp1;
  SELECT pg_ripple.insert_triple('<https://example.org/s8>','<https://example.org/p8>','<https://example.org/o8>','');
  SELECT * FROM pg_ripple.sparql('SELECT ?o WHERE { <https://example.org/s8> <https://example.org/p8> ?o }');
  SELECT id, value FROM _pg_ripple.dictionary WHERE value LIKE '%example.org/%8' ORDER BY id;
ROLLBACK;
```

```
SAVEPOINT
 ins_sub   641
              result
 {"o": "<https://example.org/o8>"}
ROLLBACK
 reins     642
   result
 {"o": null}
WARNING:  batch_decode: dictionary entry missing for id 99; result binding will be empty string (possible dictionary corruption)
 id | value
----+-------
(0 rows)
```

The re-insert wrote a triple **and created no dictionary rows at all**. Cause, in the
extension:

- `src/lib.rs:588` `sub_xact_callback_c` handles `SUBXACT_EVENT_ABORT_SUB` by calling
  `dictionary::invalidate_decode_cache()` (`src/dictionary/mod.rs:891`), which clears the two
  **backend-local** LRUs.
- It does **not** touch `TX_SHMEM_INSERTS` (`src/dictionary/mod.rs:91`) or evict from the
  **shared-memory** encode cache. Only the top-level abort path,
  `dictionary::clear_caches()` (`src/dictionary/mod.rs:869`), does that.
- So after the savepoint rollback, shmem still maps `hash(term) → id` for ids whose
  dictionary rows are gone. The next `encode()` takes the Tier-1 shmem hit
  (`src/dictionary/mod.rs:135`), skips the SPI upsert, and writes VP rows against dead ids.

This is **not** fixed by a reconnect — the cache is shared memory, not backend-local. In a
brand-new session, after the above:

```
 id |         value
----+------------------------
 82 | https://example.org/e1        -- (the subject survived; the other two terms are gone)
 insert_triple | 0
 id | value
(0 rows)
   result
 {"o": null}
WARNING:  batch_decode: dictionary entry missing for id 86; …
```

And if the enclosing transaction **commits**, the corruption is durable. From a fresh
session, after one committed savepoint round:

```sql
SELECT v.s, v.p, v.o FROM _pg_ripple.vp_rare v
WHERE NOT EXISTS (SELECT 1 FROM _pg_ripple.dictionary d WHERE d.id = v.s)
   OR NOT EXISTS (SELECT 1 FROM _pg_ripple.dictionary d WHERE d.id = v.p)
   OR NOT EXISTS (SELECT 1 FROM _pg_ripple.dictionary d WHERE d.id = v.o);
```

```
 s  | p  | o
----+----+----
 82 | 85 | 86

WARNING:  batch_decode: dictionary entry missing for id 85; …
WARNING:  batch_decode: dictionary entry missing for id 86; …
                             result
 {"o": "<https://example.org/f1>", "p": "<https://example.org/knows>", "s": "<https://example.org/e1>"}
 {"o": null, "p": null, "s": "<https://example.org/e1>"}
 {"o": "<https://example.org/k1>", "p": "<https://example.org/knows>", "s": "<https://example.org/j1>"}
```

`pg_ripple.flush_encode_cache()` repairs the *cache* (a subsequent insert mints fresh ids
126/127 and the read returns `<https://example.org/g1>`), but it does not repair rows already
written. Those are unrecoverable.

Mitigating, and the reason our suite has not seen it: a **top-level** `ROLLBACK` heals the
shmem poisoning, because `TX_SHMEM_INSERTS` accumulates across the whole top-level
transaction including subtransaction encodes. Measured with fresh terms:

```
=== inside the transaction, after ROLLBACK TO SAVEPOINT ===
   result       {"o": null}
WARNING:  batch_decode: dictionary entry missing for id 131; …
=== after the top-level ROLLBACK, same session, same terms ===
 id  |         value
 133 | https://example.org/y1
 134 | https://example.org/yp
 135 | https://example.org/y2
              result
 {"o": "<https://example.org/y2>"}
```

So defect B is bounded by the enclosing transaction: harmless if it aborts, permanent if it
commits. That makes it a **production** bug, and it is reachable from Rails by the most
ordinary route there is — `transaction(requires_new: true)` and any nested
`ActiveRecord::Rollback` compile to `SAVEPOINT` / `ROLLBACK TO SAVEPOINT`.

---

## e. Writes are unaffected; only reads lie (defect A)

Defect A does not break writing. In the poisoned round the write lands correctly under the
new ids and only the cached read cannot see it:

```
=== e1 ===
 upd_again            1
 read_after_rollback  0     -- pg_ripple.sparql(), poisoned plan
 raw_rows_present     1     -- _pg_ripple.vp_rare joined to the CURRENT dictionary id
```

`pg_ripple.sparql_update` poisons in exactly the same way a `SELECT` does, because the
`INSERT DATA` constants are encoded on the same path — but its *effect* is correct; it is the
subsequent read of the same query text that returns nothing.

Defect B is the opposite: the write is what is wrong.

---

## Consequences for this gem

1. **`PgRipple::TestHelpers.reset_dictionary_cache!` is misnamed and over-broad.** It works,
   because a new backend gets an empty plan cache — but it works by accident, it drops the
   host application's whole pool, and its documentation states a mechanism that this probe
   disproves. `spec-corrections.md` §11, `lib/pg_ripple/test_helpers.rb` and the README's
   "Testing" section all need correcting, not just the workaround.

2. **This is not a test-only hazard, and the README should stop implying it is.** In
   production, any aborted transaction poisons that pooled connection's plan cache for every
   query whose constants it was the first to mint. The dangerous shape is a *stable* constant:
   `Person.graph.where(role: "engineer")` mints `"engineer"` once, ever. If the transaction
   that first minted it aborts, that connection answers that query with zero rows for the
   rest of its life, and the other connections in the pool answer correctly. That is the
   worst possible failure mode — silent, partial, and load-balanced.

3. **`graph_has_many` traversals are the most exposed queries in the gem**, because the
   subject IRI is a constant in every one of them (`<https://app.example.com/people/1>
   foaf:knows+ ?iri`). A failed `Person.create!` mints that IRI and aborts; every later
   `alice.network` on that connection returns `[]`.

## Recommendation — the narrowest correct fix

> **Applied.** All four points below are implemented; see `docs/spec-corrections.md` §16 for
> what shipped, including the decision point (2) left open: the rollback hook marks the
> connection and the reset runs lazily at the gem's next statement, rather than issuing a
> query from inside `#exec_rollback_db_transaction`.

**This is an extension bug. Do not paper over it in Ruby beyond the minimum needed to keep a
suite honest, and file it upstream.** Draft below.

For the gem, in order:

1. **Replace the `disconnect!` workaround with `SELECT pg_ripple.plan_cache_reset()`** on the
   leased connection. It is the actual invalidation, it costs one round trip instead of a
   pool teardown, it does not reach into a host application's pool, and it is measurably
   sufficient (§c: 1, 1, 1 on one connection). Rename the helper to say what it does —
   `reset_plan_cache!` — and keep `reset_dictionary_cache!` as a deprecated alias for one
   release, since it is already documented in the README.

2. **Do not stop at the test helper.** Because §2 above is a production failure, the gem
   should also reset the plan cache on the connection whenever a transaction it participated
   in rolls back. `ActiveSupport::Notifications` will not do — the reliable seam is
   `ActiveRecord::ConnectionAdapters::AbstractAdapter#rollback_db_transaction` /
   `#exec_rollback_db_transaction`, or a `after_rollback`-style hook registered per
   connection. That is a design decision for phase 2, not something to settle here; the two
   candidate spellings and their cost should be measured before choosing. What is settled is
   that "call this in your test suite" is not a sufficient answer to a bug that fires in
   production.

3. **Defect B needs a guard rail, not a workaround.** There is nothing the gem can do to make
   `ROLLBACK TO SAVEPOINT` safe — `flush_encode_cache()` after every savepoint rollback would
   throw away a shared, process-wide cache on every nested transaction in the application,
   which is not a trade a gem may make silently. The honest response is to document it in
   "Where the abstraction leaks" as a **known upstream data-corruption bug**, name the
   affected versions, and say plainly that `transaction(requires_new: true)` around graph
   writes is unsafe on pg_ripple 0.128.0. Our own `spec/acceptance/transactions_spec.rb`
   (§13) uses `requires_new: true`; its outer rollback means the suite never commits the
   corruption, but it should carry a comment pointing here.

4. **Do not "fix" this by disabling the plan cache.** There is no working switch (§c), and
   the cache is worth 40× on translation-heavy workloads.

---

## Upstream issue, draft

> **Title:** SPARQL plan cache is not invalidated on transaction abort — queries silently
> return zero rows (0.128.0)
>
> **Summary.** `src/sparql/plan_cache.rs` caches generated SQL that contains dictionary ids
> as integer literals (`src/sparql/sqlgen.rs:370`, `src/sparql/plan.rs:119`). On
> `XACT_EVENT_ABORT`, `xact_callback_c` (`src/lib.rs:534`) clears the dictionary caches and
> the mutation journal but not the plan cache. The dictionary rows minted by the aborted
> transaction are gone and the next transaction mints new ids, so a cached plan for the same
> query now filters on ids that no longer exist and the query returns **zero rows**, silently
> and indefinitely, on that backend.
>
> **Reproduction** (PostgreSQL 18.4, pg_ripple 0.128.0, `shared_preload_libraries =
> pg_ripple`), one session, three identical rounds:
>
> ```sql
> BEGIN;
> SELECT pg_ripple.insert_triple('<https://example.org/alice>','<https://example.org/knows>','<https://example.org/bob>','');
> SELECT count(*) FROM pg_ripple.sparql('SELECT ?o WHERE { <https://example.org/alice> <https://example.org/knows> ?o }');
> ROLLBACK;
> ```
>
> Expected 1, 1, 1. Actual **1, 0, 0**.
>
> `pg_ripple.plan_cache_stats()` shows round 2 as a cache hit.
> `pg_ripple.explain_sparql(q,'sql')` shows `WHERE p = 31 … s = 30` in round 1 and
> `p = 35 … s = 34` in round 2, while the cached plan still uses 30/31.
> `pg_ripple.plan_cache_reset()` restores correct behaviour; `DISCARD ALL`,
> `pg_ripple.flush_encode_cache()` and `pg_ripple.invalidate_catalog_cache()` do not.
> A query with no IRI/literal constants is unaffected. A failed statement (e.g. `SELECT 1/0`)
> triggers it as readily as an explicit `ROLLBACK`; `COMMIT` never does.
>
> **Suggested fix.** Call `crate::sparql::plan_cache::reset()` from `xact_callback_c` on
> `XACT_EVENT_ABORT` / `XACT_EVENT_PARALLEL_ABORT`, alongside `dictionary::clear_caches()`.
> A cheaper alternative that avoids throwing the whole cache away: include a
> dictionary-generation counter in `cache_key_inner` and bump it on abort, the same way
> `schema_generation` already invalidates plans after VP-table creation.
>
> **Also:** `pg_ripple.plan_cache_size` is documented as "0 = disabled" but `PLAN_CACHE_SIZE`
> is only read by `src/sparql/explain.rs:120`; setting it to 0 does not disable the cache.
> There is therefore no way to work around this by configuration.

> **Title:** `ROLLBACK TO SAVEPOINT` leaves stale entries in the shared-memory encode cache —
> triples are written against non-existent dictionary ids (0.128.0)
>
> **Summary.** `sub_xact_callback_c` (`src/lib.rs:588`) handles `SUBXACT_EVENT_ABORT_SUB` by
> calling `dictionary::invalidate_decode_cache()`, which clears the two backend-local LRUs. It
> does not evict the entries the subtransaction pushed onto `TX_SHMEM_INSERTS`
> (`src/dictionary/mod.rs:91`) from the shared-memory encode cache; only the top-level abort
> path `dictionary::clear_caches()` (`src/dictionary/mod.rs:869`) does that. After a savepoint
> rollback, `encode()` therefore takes a Tier-1 shmem hit for a term whose dictionary row was
> just rolled back, skips the SPI upsert, and returns a dead id. Triples are then written
> against ids with no dictionary row. **If the enclosing transaction commits, the corruption
> is durable and unrecoverable.**
>
> **Reproduction**, fresh session, brand-new terms:
>
> ```sql
> BEGIN;
>   SAVEPOINT sp1;
>     SELECT pg_ripple.insert_triple('<https://example.org/s8>','<https://example.org/p8>','<https://example.org/o8>','');
>   ROLLBACK TO SAVEPOINT sp1;
>   SELECT pg_ripple.insert_triple('<https://example.org/s8>','<https://example.org/p8>','<https://example.org/o8>','');
>   SELECT * FROM pg_ripple.sparql('SELECT ?o WHERE { <https://example.org/s8> <https://example.org/p8> ?o }');
>   SELECT id, value FROM _pg_ripple.dictionary WHERE value LIKE '%example.org/%8';
> COMMIT;
> ```
>
> ```
>    result
>  {"o": null}
> WARNING:  batch_decode: dictionary entry missing for id 99; result binding will be empty string (possible dictionary corruption)
>  id | value
> ----+-------
> (0 rows)
> ```
>
> After `COMMIT`, from any session:
>
> ```sql
> SELECT v.s, v.p, v.o FROM _pg_ripple.vp_rare v
> WHERE NOT EXISTS (SELECT 1 FROM _pg_ripple.dictionary d WHERE d.id = v.p);
> --  s  | p  | o
> --  82 | 85 | 86
> ```
>
> The poisoning is in shared memory, so a **new backend** sees it too; only
> `pg_ripple.flush_encode_cache()` or a top-level `ROLLBACK` clears it, and neither repairs
> rows already written.
>
> **Impact.** Any ORM that uses savepoints for nested transactions hits this on ordinary code.
> Rails' `transaction(requires_new: true)` and a nested `ActiveRecord::Rollback` are exactly
> this pattern.
>
> **Suggested fix.** Track shmem insertions per subtransaction nesting level and evict the
> current level's entries on `SUBXACT_EVENT_ABORT_SUB`, promoting them to the parent level on
> `SUBXACT_EVENT_COMMIT_SUB`. A blunt but correct interim fix is to evict all of
> `TX_SHMEM_INSERTS` on `SUBXACT_EVENT_ABORT_SUB`, since over-eviction only costs an SPI
> round-trip while under-eviction corrupts data.

---

## Container hygiene

Created for this probe and removed at the end of it:
`docker run -d --rm --name ripple-cachediag-p1 -p 127.0.0.1:0:5432 -e POSTGRES_PASSWORD=…
ghcr.io/trickle-labs/pg-ripple:0.128.0`. No volume, no network, port bound to loopback on an
ephemeral port. No other container was touched.

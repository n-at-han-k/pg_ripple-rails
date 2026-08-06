# What the reference gems do, and which parts are load-bearing

Study of [`teoljungberg/fx`](https://github.com/teoljungberg/fx) and
[`n-at-han-k/pg_cron-rails`](https://github.com/n-at-han-k/pg_cron-rails), the two gems this
one is modelled on. Clone both into `references/` (gitignored) to follow along.

## The shape both gems share

Neither gem wraps the database object in an ActiveRecord model. Both do exactly one thing:
teach ActiveRecord's migration DSL, rollback machinery, and schema dumper about a database
object Rails does not know exists. Eight files, always the same eight:

| File | Job |
|---|---|
| `lib/<gem>.rb` | `self.load` — the three mix-ins, in order |
| `lib/<gem>/railtie.rb` | calls `load` on `ActiveSupport.on_load :active_record` |
| `lib/<gem>/configuration.rb` | swappable adapter, dump-ordering flags |
| `lib/<gem>/adapters/postgres.rb` | the only place that executes SQL |
| `lib/<gem>/adapters/postgres/<objects>.rb` | one catalog query → array of value objects |
| `lib/<gem>/definition.rb` | `(name, version)` → path of a file on disk → its contents |
| `lib/<gem>/statements.rb` | `create_x` / `update_x` / `drop_x`, mixed into `AbstractAdapter` |
| `lib/<gem>/command_recorder.rb` | `invert_create_x` etc., mixed into `CommandRecorder` |
| `lib/<gem>/schema_dumper.rb` | prepended to `SchemaDumper`, writes objects into `schema.rb` |
| `lib/<gem>/<object>.rb` | value object with `#to_schema` |
| `lib/generators/<gem>/<object>/` | generator + `create_x.erb` / `update_x.erb` templates |

`Fx.load` is the whole integration surface:

```ruby
ActiveRecord::Migration::CommandRecorder.include(Fx::CommandRecorder)
ActiveRecord::ConnectionAdapters::AbstractAdapter.include(Fx::Statements)
ActiveRecord::SchemaDumper.prepend(Fx::SchemaDumper)
```

## The five decisions worth copying

**1. Versioned definition files, not inline SQL.** `Fx::Definition` maps
`(name: :uppercase_name, version: 2)` to `db/functions/uppercase_name_v02.sql`, checking each
engine's `db/migrate` sibling directories before the host app's. A migration says
`create_function :uppercase_name, version: 2`; the SQL lives in a file that a linter, a diff,
and code review can all see. `sql_definition:` is the escape hatch — and the form the schema
dumper emits, since a dumped object has no version.

**2. `revert_to_version` is what makes it reversible.** `CommandRecorder#invert_drop_function`
rewrites the args, swapping `revert_to_version:` in as `version:`. Without it,
`ActiveRecord::IrreversibleMigration`. This is the only interesting logic in the recorder;
everything else is `record(:create_function, args)` plus `ruby2_keywords`.

**3. Hook `#tables`, not `#extensions`.** Both schema dumpers override `tables` and call
`super`. `#extensions` is private *and* redefined by the PostgreSQL-specific dumper, so a
prepended module never intercepts it and the dump silently comes out empty. `fx` adds
`dump_functions_at_beginning_of_schema` because a column default may call a function that must
already exist at load time; `pg_cron` always dumps after `super` because a schedule's command
generally calls the functions above it.

**4. Round-trip fidelity is a property of the extension, not the gem.** `fx` dumps verbatim
because `pg_get_functiondef` hands back the original statement. pg_cron stores only the *parts*
— `jobname`, `schedule`, `command` — so `PgCron::Job#definition` rebuilds a `cron.schedule()`
call from them, dollar-quoting the command as `$job$…$job$` so a command containing its own `$$`
still nests. Before designing a dumper, check what the extension's catalog actually retains.

**5. Prefix every method mixed into `AbstractAdapter`.** The single hardest-won lesson in
`pg_cron-rails`, and it is written up at length in `lib/pg_cron/statements.rb`. Both gems are
included into the *same* object. `pg_cron` was included second, and its private
`resolve_sql_definition` — lifted from `fx` but one argument shorter — shadowed `fx`'s for the
whole application. Every `create_function` in the host app died on `ArgumentError: wrong number
of arguments (given 4, expected 3)` before reaching the database. Prefixing (`resolve_cron_sql_definition`)
fixes it permanently; matching `fx`'s arity only fixes it until `fx` changes. `spec/pg_cron/fx_coexistence_spec.rb`
exists because of this, and `fx` is a development dependency purely so that spec can run.

## Where pg_cron diverged, and why

- **`pg_cron_enabled?` guard on every statement.** A migration that schedules a job still runs
  against a database without the extension instead of every such migration needing its own
  guard. The adapter's `jobs` returns `[]` when absent, so `db:schema:dump` does not fail on a
  database that simply has no cron.
- **`update_job` is one statement, not drop-then-create.** `cron.schedule()` against an existing
  jobname replaces it. Dropping first leaves a window with no schedule, which on a
  minutely job is a missed run. It does check existence first, so an out-of-order migration
  fails loudly instead of silently creating a job.
- **Identity is the name, not a signature.** `Fx::Function#<=>` compares `name(arg_types)`
  because Postgres allows overloads. pg_cron keys on `jobname` alone.
- **The adapter uses the application's own connection.** An earlier version opened a second
  connection to a database named `postgres`; pg_cron's row-level security on `cron.job` filters
  by username, so jobs created on a different connection as a different role were invisible to
  both the app and the dumper.

## Testing layout

`fx` is the more complete model: `spec/dummy` (a minimal Rails app — `config/application.rb`,
`database.yml`, `db/migrate/.keep`, nothing else), unit specs mirroring `lib/`, `spec/features/`
running real migrations against a real Postgres, `spec/features/*/revert_spec.rb` proving
rollback, and `spec/acceptance/` driving the generators end to end. `pg_cron` adds
`spec/pg_cron/fx_coexistence_spec.rb`.

CI in both is a Ruby × Rails matrix against a Postgres service container. `pg_ripple` needs
PostgreSQL 18 with the extension present, so the service image must be a pg_ripple build rather
than stock `postgres:18`.

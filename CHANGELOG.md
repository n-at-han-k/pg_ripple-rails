# Changelog

The noteworthy changes for each version are included here.

## [Unreleased]

### Added

- Initial gem scaffold: `PgRipple.load` wiring the three mix-ins
  (`CommandRecorder`, `Statements`, `SchemaDumper`), `PgRipple::Configuration`
  carrying the adapter and `dump_ripple_objects_at_beginning_of_schema`, and the
  railtie that calls `load` on `ActiveSupport.on_load :active_record`.

### Known limitations

- **SHACL shapes do not round-trip.** `_pg_ripple.shacl_shapes` stores the
  parsed `shape_json` only; the Turtle you loaded is gone, there is no
  `export_shacl()`, and `sh:severity` / `sh:name` / `sh:description` / `sh:order`
  are dropped outright. The dumper emits a comment rather than a reconstructed
  `load_shacl`, and `rake pg_ripple:shapes:load` replays the definition files.
- **Named graphs are not managed.** `create_graph` creates no catalog row and
  `list_graphs()` derives its answer from the triples present, so a graph cannot
  be dumped without making `schema.rb` data-dependent.
- **SPARQL views need pg_trickle**, which the published image ships but neither
  `CREATE EXTENSION pg_ripple` nor `CASCADE` installs.

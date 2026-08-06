# frozen_string_literal: true

# `strip_heredoc` on an inline definition, `present?` in the validators. Rails
# has both loaded long before a migration runs; required explicitly so the gem
# also works in a plain ActiveRecord process, which is the same reason
# lib/pg_ripple.rb requires "active_record" rather than "rails".
require "active_support/core_ext/object/blank"
require "active_support/core_ext/string/strip"

module PgRipple
  # Migration methods for the pg_ripple objects that are schema: namespace
  # prefixes, SHACL shape sets, Datalog rule sets, SPARQL views and federation
  # endpoints.
  #
  # F(x)'s conventions throughout — a name, an optional `version:` naming a file
  # under `db/ripple`, an optional inline `definition:` that takes its place,
  # and `revert_to_version:` so a rollback restores the previous definition
  # instead of dropping the object outright — with three differences that come
  # from the extension rather than from taste.
  #
  # **`definition:`, not `sql_definition:`.** The inline escape hatch takes a
  # Turtle, Datalog or SPARQL document. Calling the argument `sql_definition`
  # would be a lie in every one of the five cases, and would invite someone to
  # pass SQL.
  #
  # **Prefixes and endpoints have no version.** They are two and four scalars,
  # with no document and so no file, so they take no `version:` and their drops
  # invert through `revert_to_expansion:` / `revert_to:` instead. Only the three
  # document kinds get the F(x) treatment.
  #
  # **Named graphs are absent on purpose.** `create_graph` interns an IRI in the
  # term dictionary and writes no catalog row; `list_graphs()` derives its
  # answer from the triples present, so an empty graph is invisible and a
  # populated one shows up whether or not a migration declared it. It is seed
  # data, not schema. See `docs/probe-results.md` §3.
  #
  # Nothing here guards on the extension: every method on
  # {PgRipple::Adapters::Postgres} already no-ops when pg_ripple is absent, and
  # duplicating the check here would only mean two places to get it wrong.
  # Definition files are still read in that case, which is deliberate — a
  # migration naming a file that does not exist should fail on every database,
  # not only on the ones with a triple store.
  module Statements
    # Register a namespace prefix.
    #
    # `register_prefix` upserts on the prefix, so this is create and update
    # both; there is no `update_ripple_prefix`.
    #
    # @param prefix [String, Symbol] The prefix, without its colon.
    # @param expansion [String] The IRI the prefix abbreviates.
    # @return [void]
    #
    # @example
    #   create_ripple_prefix :foaf, "http://xmlns.com/foaf/0.1/"
    #
    def create_ripple_prefix(prefix, expansion)
      PgRipple.database.create_prefix(prefix, expansion)
    end

    # Remove a namespace prefix.
    #
    # @param prefix [String, Symbol] The prefix to remove.
    # @param revert_to_expansion [String] Used to reverse this on
    #   `rake db:rollback`; passed as `expansion` to {#create_ripple_prefix}.
    #   A prefix carries no version, so this scalar plays the part
    #   `revert_to_version` plays for the document kinds — without it the
    #   migration is irreversible.
    # @return [void]
    #
    # @example
    #   drop_ripple_prefix :foaf, revert_to_expansion: "http://xmlns.com/foaf/0.1/"
    #
    def drop_ripple_prefix(prefix, revert_to_expansion: nil)
      PgRipple.database.drop_prefix(prefix)
    end

    # Load a SHACL shape set from `db/ripple/shapes`.
    #
    # @param name [String, Symbol] The name of the shape set — the file's
    #   basename, and this gem's only handle on it. pg_ripple has none: it
    #   shreds the document into one row per shape IRI with no grouping key.
    # @param version [Integer] The version number, used to find the definition
    #   file in `db/ripple/shapes`. Defaults to `1`.
    # @param definition [String] Turtle source, in place of a file. Mutually
    #   exclusive with `version`.
    # @param revert_to_version [Integer] The version to roll back to.
    # @return [void]
    #
    # @example Load `db/ripple/shapes/person_v01.ttl`
    #   create_ripple_shapes :person, version: 1
    #
    # @example Load from a provided Turtle string
    #   create_ripple_shapes(:person, definition: <<~TTL)
    #     @prefix sh: <http://www.w3.org/ns/shacl#> .
    #     @prefix ex: <https://example.org/> .
    #
    #     ex:PersonShape a sh:NodeShape ;
    #       sh:targetClass ex:Person ;
    #       sh:property [ sh:path ex:name ; sh:minCount 1 ] .
    #   TTL
    #
    def create_ripple_shapes(name, version: nil, definition: nil, revert_to_version: nil)
      validate_ripple_version_and_definition_exclusive!(version, definition)
      version ||= 1

      PgRipple.database.create_shapes(resolve_ripple_definition(definition, name, version, :shapes))
    end

    # Reload a SHACL shape set, dropping the shapes it no longer declares.
    #
    # One `load_shacl` call, not drop-then-load: `_pg_ripple.shacl_shapes` is
    # keyed on `shape_iri` and the load upserts the whole parsed shape for each
    # IRI it finds, so a shape in both versions is replaced rather than merged.
    #
    # What the load does not handle is a shape the OLD version declared and the
    # new one does not. It stays in the catalog, stays active, and keeps
    # validating every insert — and the catalog cannot find it, because it
    # records neither the file a shape came from nor anything else to group by.
    # So the orphans are worked out from the previous version's file on disk and
    # dropped explicitly, in the same transaction as the load.
    #
    # **`revert_to_version` is what identifies that previous version**, and this
    # is the one place where it does more than describe a rollback. Omitting it
    # makes the migration irreversible *and* silently skips the sweep, which is
    # why every generated `update` template fills it in.
    #
    # @param name [String, Symbol] The name of the shape set.
    # @param version [Integer] The version to load.
    # @param definition [String] Turtle source, in place of a file. Mutually
    #   exclusive with `version`.
    # @param revert_to_version [Integer] The version to roll back to, and the
    #   version whose shapes are swept for orphans.
    # @return [void]
    #
    # @example
    #   update_ripple_shapes :person, version: 2, revert_to_version: 1
    #
    def update_ripple_shapes(name, version: nil, definition: nil, revert_to_version: nil)
      validate_ripple_version_or_definition_present!(version, definition)
      validate_ripple_version_and_definition_exclusive!(version, definition)

      document = resolve_ripple_definition(definition, name, version, :shapes)

      PgRipple.database.update_shapes(
        document,
        ripple_orphaned_shape_iris(name, revert_to_version, document)
      )
    end

    # Drop every shape a shape set declares.
    #
    # `drop_shape` takes one IRI and pg_ripple offers no "drop everything that
    # file loaded", so the IRIs come from the file: a version or an inline
    # definition is required, and it must be the one currently loaded.
    #
    # @param name [String, Symbol] The name of the shape set.
    # @param version [Integer] The version currently loaded, whose file names
    #   the shapes to drop.
    # @param definition [String] Turtle source, in place of a file.
    # @param revert_to_version [Integer] Used to reverse this on
    #   `rake db:rollback`; passed as `version` to {#create_ripple_shapes}.
    # @return [void]
    #
    # @example
    #   drop_ripple_shapes :person, version: 2, revert_to_version: 2
    #
    def drop_ripple_shapes(name, version: nil, definition: nil, revert_to_version: nil)
      validate_ripple_version_or_definition_present!(version, definition)
      validate_ripple_version_and_definition_exclusive!(version, definition)

      document = resolve_ripple_definition(definition, name, version, :shapes)

      ripple_shape_iris_declared_in(document).each do |shape_iri|
        PgRipple.database.drop_shape(shape_iri)
      end
    end

    # Load a Datalog rule set from `db/ripple/rules`.
    #
    # @param name [String, Symbol] The name of the rule set. This is its
    #   identity in `_pg_ripple.rule_sets` — loading over an existing name
    #   replaces it.
    # @param version [Integer] The version number, used to find the definition
    #   file in `db/ripple/rules`. Defaults to `1`.
    # @param definition [String] Datalog source, in place of a file. Mutually
    #   exclusive with `version`.
    # @param revert_to_version [Integer] The version to roll back to.
    # @return [void]
    #
    # @example Load `db/ripple/rules/org_chart_v01.dl`
    #   create_ripple_rules :org_chart, version: 1
    #
    # @example Load from a provided Datalog string
    #   create_ripple_rules(:org_chart, definition: <<~DL)
    #     ?x <https://example.org/ancestor> ?y :- ?x <https://example.org/parent> ?y .
    #   DL
    #
    def create_ripple_rules(name, version: nil, definition: nil, revert_to_version: nil)
      validate_ripple_version_and_definition_exclusive!(version, definition)
      version ||= 1

      PgRipple.database.create_rules(name, resolve_ripple_definition(definition, name, version, :rules))
    end

    # Replace a Datalog rule set.
    #
    # One `load_rules` call, not `drop_rules` then `load_rules`. The load
    # already replaces a set of the same name — delete then insert, proved by
    # the rule identities advancing — and dropping first is not merely
    # redundant but destructive: `drop_rules` also retracts the materialised
    # inferences that a straight reload preserves.
    #
    # @param name [String, Symbol] The name of the rule set.
    # @param version [Integer] The version to load.
    # @param definition [String] Datalog source, in place of a file.
    # @param revert_to_version [Integer] The version to roll back to.
    # @return [void]
    #
    # @example
    #   update_ripple_rules :org_chart, version: 2, revert_to_version: 1
    #
    def update_ripple_rules(name, version: nil, definition: nil, revert_to_version: nil)
      validate_ripple_version_or_definition_present!(version, definition)
      validate_ripple_version_and_definition_exclusive!(version, definition)

      PgRipple.database.update_rules(name, resolve_ripple_definition(definition, name, version, :rules))
    end

    # Deactivate a Datalog rule set, leaving its rules in place.
    #
    # `disable_rule_set` clears `rule_sets.active`: the set stops contributing
    # to inference, its rules stay in the catalog, and the triples it already
    # inferred are not retracted. That last part is the difference from
    # {#drop_ripple_rules}.
    #
    # This pair exists because the dumper needs it. `load_rules` always
    # produces an *active* rule set, so a `schema.rb` that emitted
    # `create_ripple_rules` alone for a set the source database had disabled
    # would rebuild a database that infers where the original did not — a
    # silent difference in what the store contains, not merely in what the
    # catalog says.
    #
    # @param name [String, Symbol] The name of the rule set.
    # @return [void]
    #
    # @example
    #   disable_ripple_rules :owl_rl
    #
    def disable_ripple_rules(name)
      PgRipple.database.disable_rules(name)
    end

    # Reactivate a Datalog rule set.
    #
    # @param name [String, Symbol] The name of the rule set.
    # @return [void]
    #
    # @example
    #   enable_ripple_rules :owl_rl
    #
    def enable_ripple_rules(name)
      PgRipple.database.enable_rules(name)
    end

    # Drop a Datalog rule set, retracting what it inferred.
    #
    # Keyed on the name alone — unlike shapes, a rule set is a catalog row and
    # dropping it needs no file.
    #
    # @param name [String, Symbol] The name of the rule set.
    # @param revert_to_version [Integer] Used to reverse this on
    #   `rake db:rollback`; passed as `version` to {#create_ripple_rules}.
    # @return [void]
    #
    # @example
    #   drop_ripple_rules :org_chart, revert_to_version: 2
    #
    def drop_ripple_rules(name, revert_to_version: nil)
      PgRipple.database.drop_rules(name)
    end

    # Create a SPARQL view from `db/ripple/views`.
    #
    # A view is a scheduled, incrementally-maintained pg_trickle stream table,
    # so `schedule` and `decode` are part of its definition and round-trip
    # through the dump alongside the query. They are always sent explicitly
    # rather than left to the server's defaults, so the dumped value and the
    # created value cannot drift apart. `immediate` is not stored anywhere and
    # so cannot be dumped; it is an argument here and a default in `schema.rb`.
    #
    # Requires pg_trickle, which `CREATE EXTENSION pg_ripple` does not install
    # and `CASCADE` does not pull in. Without it this raises
    # {PgRipple::MissingExtensionError} rather than skipping quietly.
    #
    # @param name [String, Symbol] The name of the view, and of the stream table
    #   the application queries.
    # @param version [Integer] The version number, used to find the definition
    #   file in `db/ripple/views`. Defaults to `1`.
    # @param definition [String] SPARQL source, in place of a file. Mutually
    #   exclusive with `version`.
    # @param schedule [String] Refresh interval, e.g. `"1s"`, `"5 minutes"`.
    # @param decode [Boolean] Decode term ids to their lexical values.
    # @param immediate [Boolean] Populate the stream table on creation.
    # @param revert_to_version [Integer] The version to roll back to.
    # @return [void]
    #
    # @example Create from `db/ripple/views/people_v01.rq`, refreshed every minute
    #   create_ripple_sparql_view :people, version: 1, schedule: "1 minute", decode: true
    #
    def create_ripple_sparql_view(
      name,
      version: nil,
      definition: nil,
      schedule: PgRipple::Adapters::Postgres::DEFAULT_VIEW_SCHEDULE,
      decode: false,
      immediate: false,
      revert_to_version: nil
    )
      validate_ripple_version_and_definition_exclusive!(version, definition)
      version ||= 1

      PgRipple.database.create_sparql_view(
        name,
        resolve_ripple_definition(definition, name, version, :views),
        schedule: schedule,
        decode: decode,
        immediate: immediate
      )
    end

    # Replace a SPARQL view.
    #
    # One `create_sparql_view` call. The unconditional `drop_stream_table` that
    # breaks a *first* creation upstream is exactly what makes a re-creation
    # work, so an update needs no drop of its own — and dropping first would
    # leave the application reading an absent relation until the next refresh
    # completed.
    #
    # @param (see #create_ripple_sparql_view)
    # @return [void]
    #
    # @example
    #   update_ripple_sparql_view :people, version: 2, revert_to_version: 1
    #
    def update_ripple_sparql_view(
      name,
      version: nil,
      definition: nil,
      schedule: PgRipple::Adapters::Postgres::DEFAULT_VIEW_SCHEDULE,
      decode: false,
      immediate: false,
      revert_to_version: nil
    )
      validate_ripple_version_or_definition_present!(version, definition)
      validate_ripple_version_and_definition_exclusive!(version, definition)

      PgRipple.database.update_sparql_view(
        name,
        resolve_ripple_definition(definition, name, version, :views),
        schedule: schedule,
        decode: decode,
        immediate: immediate
      )
    end

    # Drop a SPARQL view and its stream table.
    #
    # @param name [String, Symbol] The name of the view.
    # @param revert_to_version [Integer] Used to reverse this on
    #   `rake db:rollback`; passed as `version` to
    #   {#create_ripple_sparql_view}. Note that `schedule` and `decode` are not
    #   restored by the inversion — a rollback recreates the view with the
    #   defaults unless the migration says otherwise.
    # @return [void]
    #
    # @example
    #   drop_ripple_sparql_view :people, revert_to_version: 1
    #
    def drop_ripple_sparql_view(name, revert_to_version: nil)
      PgRipple.database.drop_sparql_view(name)
    end

    # Register a federation endpoint.
    #
    # **Keyed on the URL, not on a name** — there is no name anywhere in
    # pg_ripple's endpoint API. `register_endpoint` upserts on the URL, so this
    # is create and update both, and note that the upsert also forces `enabled`
    # back to true.
    #
    # Credentials are deliberately absent: `set_federation_credential` stores
    # pgcrypto-encrypted tokens, and a secret does not belong in a migration or
    # in a dumped schema.
    #
    # @param url [String] The endpoint's SPARQL URL.
    # @param local_view_name [String, nil] A local view to answer from instead
    #   of going over the network.
    # @param complexity [String, nil] `"fast"`, `"normal"` or `"slow"`, the
    #   planner's cost hint.
    # @param graph_iri [String, nil] The graph this endpoint stands for.
    # @return [void]
    #
    # @example
    #   create_ripple_endpoint "https://query.wikidata.org/sparql",
    #     complexity: "slow",
    #     graph_iri: "https://www.wikidata.org/"
    #
    def create_ripple_endpoint(url, local_view_name: nil, complexity: nil, graph_iri: nil)
      PgRipple.database.create_endpoint(
        url,
        local_view_name: local_view_name,
        complexity: complexity,
        graph_iri: graph_iri
      )
    end

    # Remove a federation endpoint.
    #
    # @param url [String] The URL of the endpoint to remove.
    # @param revert_to [Hash] The options to pass back to
    #   {#create_ripple_endpoint} on `rake db:rollback`. A hash rather than one
    #   `revert_to_*` keyword per attribute, because an endpoint has three
    #   optional ones and all three may legitimately be nil — so the presence of
    #   the hash, not the presence of a value in it, is what marks the migration
    #   reversible. `revert_to: {}` restores a bare endpoint.
    # @return [void]
    #
    # @example
    #   drop_ripple_endpoint "https://query.wikidata.org/sparql",
    #     revert_to: {complexity: "slow", graph_iri: "https://www.wikidata.org/"}
    #
    def drop_ripple_endpoint(url, revert_to: nil)
      PgRipple.database.drop_endpoint(url)
    end

    private

    # THE `ripple_` ON EVERY NAME BELOW IS LOAD-BEARING. Do not tidy it away.
    #
    # This module and F(x)'s Statements are included into the SAME object,
    # ActiveRecord::ConnectionAdapters::AbstractAdapter, and whichever is
    # included second wins — so anything here sharing a name with F(x) shadows
    # F(x)'s copy for every migration in the application, not only for ours.
    #
    # pg_cron-rails learned this the expensive way. It lifted F(x)'s private
    # `resolve_sql_definition` under F(x)'s own name, one argument shorter, and
    # every `create_function` and `create_trigger` in any app running both gems
    # died on
    #
    #   ArgumentError: wrong number of arguments (given 4, expected 3)
    #
    # before it reached the database. Nothing was wrong with the caller's SQL;
    # the two DSLs simply could not both be in the room. An app that wants a
    # triple store is very likely to want F(x) too, so assume the collision.
    #
    # Prefixing rather than matching F(x)'s arity, because "works as long as
    # F(x) keeps that signature" is the same bug with a longer fuse. A name that
    # is ours cannot collide at all. `spec/pg_ripple/coexistence_spec.rb` loads
    # F(x) and pg_cron alongside this gem and asserts all three DSLs still work.
    VERSION_OR_DEFINITION_REQUIRED = "version or definition must be specified"
    private_constant :VERSION_OR_DEFINITION_REQUIRED

    VERSION_AND_DEFINITION_EXCLUSIVE = "definition and version cannot both be set"
    private_constant :VERSION_AND_DEFINITION_EXCLUSIVE

    def validate_ripple_version_or_definition_present!(version, definition)
      raise ArgumentError, VERSION_OR_DEFINITION_REQUIRED, caller if version.nil? && definition.nil?
    end

    def validate_ripple_version_and_definition_exclusive!(version, definition)
      raise ArgumentError, VERSION_AND_DEFINITION_EXCLUSIVE, caller if version.present? && definition.present?
    end

    def resolve_ripple_definition(definition, name, version, kind)
      return definition.strip_heredoc if definition

      case kind
      when :shapes
        PgRipple::Definition.shapes(name: name, version: version)
      when :rules
        PgRipple::Definition.rules(name: name, version: version)
      when :views
        PgRipple::Definition.views(name: name, version: version)
      else
        raise ArgumentError, "Unknown kind: #{kind}. Must be :shapes, :rules or :views", caller
      end.to_document
    end

    # Shape IRIs the previous version declared and the new one does not.
    #
    # Empty when no previous version is known, which is the honest answer rather
    # than a safe one: nothing here can tell "there were no orphans" from "we
    # were not told where to look". The previous version's file must still
    # exist — deleting it after the migration that superseded it is what makes
    # this raise, and failing loudly beats leaving a shape validating forever.
    def ripple_orphaned_shape_iris(name, previous_version, document)
      return [] if previous_version.nil?

      previous = PgRipple::Definition.shapes(name: name, version: previous_version).to_document

      ripple_shape_iris_declared_in(previous) - ripple_shape_iris_declared_in(document)
    end

    # The node shape IRIs a Turtle document declares.
    #
    # A regex, not a Turtle parser. The gem takes no runtime dependencies, and
    # the question asked here is narrow: which subjects in this file are
    # `a sh:NodeShape`? Anything the regex misses is a shape that outlives its
    # file; anything it invents is an IRI `drop_shape` does not know, which is a
    # no-op. Both are recoverable, and the whole sweep runs inside the
    # migration's transaction, so a wrong guess rolls back with it.
    #
    # Prefixed names are expanded against the document's own `@prefix` (and
    # SPARQL-style `PREFIX`) declarations, because `_pg_ripple.shacl_shapes`
    # stores absolute IRIs and `drop_shape` matches on them: passing
    # `ex:PersonShape` through unexpanded would match nothing and silently
    # orphan the very shape this is here to drop. A prefix the document never
    # declares is left as written — there is nothing better to do with it.
    def ripple_shape_iris_declared_in(document)
      prefixes = document.scan(/^\s*(?:@prefix|PREFIX)\s+([^\s:]*):\s*<([^>]*)>/i).to_h

      document.scan(/^\s*(?:<([^>]*)>|([^\s:]*):([^\s:]+))\s+a\s+sh:NodeShape/).map do |absolute, prefix, local|
        next absolute if absolute

        expansion = prefixes[prefix]
        expansion ? "#{expansion}#{local}" : "#{prefix}:#{local}"
      end.uniq
    end
  end
end

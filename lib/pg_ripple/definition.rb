# frozen_string_literal: true

module PgRipple
  # Maps a `(kind, name, version)` triple to a file on disk and reads it.
  #
  # F(x)'s Definition, parameterised over the kind of document rather than over
  # the kind of database object, because pg_ripple's payloads are not SQL. A
  # shape set is Turtle, a rule set is Datalog, a view is SPARQL, and each gets
  # the file extension its own tooling expects:
  #
  #     db/ripple/shapes/person_v01.ttl    → pg_ripple.load_shacl($1)
  #     db/ripple/rules/org_chart_v01.dl   → pg_ripple.load_rules($1, $2)
  #     db/ripple/views/people_v01.rq      → pg_ripple.create_sparql_view($1, $2, …)
  #
  # Real extensions mean editors, linters and GitHub all highlight these files,
  # and a `.rq` is checkable by `rapper` or `arq` in CI — which a `.sql` holding
  # a SPARQL query in a string is not.
  #
  # Prefixes and federation endpoints have no Definition. They are two and four
  # scalars respectively, with nothing to put in a file.
  #
  # The lookup itself is F(x)'s, verbatim in behaviour: every engine's
  # `db/migrate` sibling is checked before the host application's own tree, so a
  # mountable engine can ship its ontology alongside its migrations.
  #
  # @api private
  class Definition
    SHAPES = "shapes"
    RULES = "rules"
    VIEWS = "views"

    # The directory under `db/` that holds every kind. One directory rather than
    # three top-level ones (`db/shapes`, `db/rules`, `db/views`) because
    # "views" and "rules" are words Rails and other extensions also want, and a
    # host app running F(x) already has `db/views` meaning something else
    # entirely.
    DIRECTORY = "ripple"

    # The file extension each kind is stored in.
    FILE_EXTENSIONS = {
      SHAPES => "ttl",
      RULES => "dl",
      VIEWS => "rq"
    }.freeze

    # @return [PgRipple::Definition] a SHACL shape set, `db/ripple/shapes/<name>_v01.ttl`
    def self.shapes(name:, version:)
      new(name: name, version: version, kind: SHAPES)
    end

    # @return [PgRipple::Definition] a Datalog rule set, `db/ripple/rules/<name>_v01.dl`
    def self.rules(name:, version:)
      new(name: name, version: version, kind: RULES)
    end

    # @return [PgRipple::Definition] a SPARQL view, `db/ripple/views/<name>_v01.rq`
    def self.views(name:, version:)
      new(name: name, version: version, kind: VIEWS)
    end

    def initialize(name:, version:, kind:)
      @name = name
      @version_number = version.to_i
      @kind = kind
    end

    # The document itself.
    #
    # Named `to_document`, not F(x)'s `to_sql`, because it is never SQL and is
    # never concatenated into any: the adapter binds it as a query parameter.
    #
    # @return [String]
    def to_document
      content = File.read(find_file || full_path)
      raise "Define the #{kind} document in #{path} before migrating." if content.empty?

      content
    end

    def full_path
      Rails.root.join(path)
    end

    def path
      @_path ||= File.join("db", DIRECTORY, kind, filename)
    end

    def version
      version_number.to_s.rjust(2, "0")
    end

    private

    attr_reader :name, :version_number, :kind

    def filename
      @_filename ||= "#{name}_v#{version}.#{FILE_EXTENSIONS.fetch(kind)}"
    end

    def find_file
      migration_paths.lazy
        .map { |migration_path| File.expand_path(File.join("..", "..", path), migration_path) }
        .find { |definition_path| File.exist?(definition_path) }
    end

    def migration_paths
      Rails.application.config.paths["db/migrate"].expanded
    end
  end
end

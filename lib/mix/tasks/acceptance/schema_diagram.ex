defmodule Mix.Tasks.Acceptance.SchemaDiagram do
  @moduledoc """
  Renders selected Postgres schemas as checked-in DOT and SVG artifacts.

  The task is intentionally repo-agnostic so a consuming application can run it
  after migrations in its normal development workflow, for example:

      mix acceptance.schema_diagram --repo MyApp.Repo --output docs/schema/my_app

  Keep the task standalone as well. Attaching it to `ecto.migrate` is suitable
  when a consumer's test bootstrap does not invoke that alias. When tests do
  invoke it, use precommit or a separate migration-and-documentation alias so
  unit tests do not rewrite tracked documentation. Existing artifacts are
  replaced only when their contents change.
  """

  use Mix.Task

  alias AcceptanceHarness.{SchemaArtifactWriter, SchemaDiagramArtifacts}

  @shortdoc "Generates a Postgres schema diagram without unchanged-file churn"

  @switches [repo: :string, output: :string, schemas: :string, domains_file: :string]
  @default_output "docs/schema/schema"
  @default_schemas ["public"]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} = OptionParser.parse(args, switches: @switches)

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    config = Application.get_env(:acceptance_harness, :schema_diagram, [])

    repo =
      opts
      |> Keyword.get(:repo, Keyword.get(config, :repo))
      |> parse_repo!()

    ensure_repo_started!(repo)

    output_base = Keyword.get(opts, :output, Keyword.get(config, :output, @default_output))
    schemas = opts |> Keyword.get(:schemas, Keyword.get(config, :schemas)) |> parse_schemas()

    dot = generate_dot(repo, schemas)
    write_outputs!(output_base <> ".dot", output_base <> ".svg", dot)

    domains_file = Keyword.get(opts, :domains_file, Keyword.get(config, :domains_file))

    if domains_file do
      domain_output = Keyword.get(config, :domains_output, output_base <> "_domains")
      write_domain_outputs!(repo, schemas, domains_file, domain_output)
    end
  end

  defp parse_repo!(nil) do
    Mix.raise(
      "configure :acceptance_harness, :schema_diagram, repo: MyApp.Repo or pass --repo MyApp.Repo"
    )
  end

  defp parse_repo!(repo) when is_atom(repo), do: repo

  defp parse_repo!(repo) do
    repo
    |> String.split(".")
    |> Module.concat()
  rescue
    ArgumentError -> Mix.raise("--repo must be an Elixir module, for example MyApp.Repo")
  end

  defp parse_schemas(nil), do: @default_schemas
  defp parse_schemas(schemas) when is_list(schemas), do: schemas

  defp parse_schemas(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp ensure_repo_started!(repo) do
    case Process.whereis(repo) do
      nil ->
        case repo.start_link() do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> Mix.raise("could not start #{inspect(repo)}: #{inspect(reason)}")
        end

      _pid ->
        :ok
    end
  end

  defp generate_dot(repo, schemas) do
    tables = fetch_tables(repo, schemas)
    columns = fetch_columns(repo, schemas)
    foreign_keys = fetch_foreign_keys(repo, schemas)
    columns_by_table = Enum.group_by(columns, &{&1.schema, &1.table})
    prominent_tables = prominent_tables(foreign_keys)

    node_lines =
      Enum.map(tables, fn table ->
        table_columns = Map.get(columns_by_table, {table.schema, table.name}, [])

        table_node(
          table,
          table_columns,
          MapSet.member?(prominent_tables, {table.schema, table.name})
        )
      end)

    edge_lines = Enum.map(foreign_keys, &foreign_key_edge/1)

    """
    digraph Schema {
      graph [
        rankdir=TB,
        bgcolor="transparent",
        overlap=false,
        splines=polyline,
        nodesep=0.65,
        ranksep=1.0,
        pad=0.35
      ];
      node [shape=plain, fontname="Helvetica"];
      edge [fontname="Helvetica", fontsize=10, color="#64748b", arrowsize=0.75, penwidth=1.2];

    #{Enum.join(node_lines, "\n\n")}

    #{Enum.join(edge_lines, "\n")}
    }
    """
  end

  # Tables with the most relationships are usually the useful orientation
  # points in a schema. Highlight the top three (including ties) instead of
  # requiring an application-specific list to be maintained.
  defp prominent_tables(foreign_keys) do
    relationship_counts =
      foreign_keys
      |> Enum.flat_map(fn fk ->
        [{fk.schema, fk.table}, {fk.foreign_schema, fk.foreign_table}]
      end)
      |> Enum.frequencies()

    cutoff =
      relationship_counts
      |> Map.values()
      |> Enum.sort(:desc)
      |> Enum.at(2)

    if cutoff do
      relationship_counts
      |> Enum.filter(fn {_table, count} -> count >= cutoff end)
      |> MapSet.new(fn {table, _count} -> table end)
    else
      MapSet.new()
    end
  end

  defp fetch_tables(repo, schemas) do
    query!(
      repo,
      """
      SELECT table_schema, table_name
      FROM information_schema.tables
      WHERE table_type = 'BASE TABLE' AND table_schema = ANY($1)
      ORDER BY table_schema, table_name
      """,
      [schemas]
    )
    |> Enum.map(fn [schema, name] -> %{schema: schema, name: name} end)
  end

  defp fetch_columns(repo, schemas) do
    query!(
      repo,
      """
      SELECT c.table_schema, c.table_name, c.column_name, c.data_type, c.udt_name,
             c.is_nullable, c.ordinal_position,
             EXISTS (
               SELECT 1 FROM information_schema.table_constraints tc
               JOIN information_schema.key_column_usage kcu
                 ON tc.constraint_name = kcu.constraint_name AND tc.constraint_schema = kcu.constraint_schema
               WHERE tc.constraint_type = 'PRIMARY KEY' AND tc.table_schema = c.table_schema
                 AND tc.table_name = c.table_name AND kcu.column_name = c.column_name
             ) AS primary_key
      FROM information_schema.columns c
      WHERE c.table_schema = ANY($1)
      ORDER BY c.table_schema, c.table_name, c.ordinal_position
      """,
      [schemas]
    )
    |> Enum.map(fn [schema, table, name, data_type, udt_name, nullable, _position, primary_key] ->
      %{
        schema: schema,
        table: table,
        name: name,
        type: display_type(data_type, udt_name),
        nullable?: nullable == "YES",
        primary_key?: primary_key
      }
    end)
  end

  @doc false
  def fetch_foreign_keys(repo, schemas) do
    query!(
      repo,
      """
      SELECT source_schema.nspname, source_table.relname, source_column.attname,
             target_schema.nspname, target_table.relname, target_column.attname
      FROM pg_catalog.pg_constraint constraint_record
      JOIN pg_catalog.pg_class source_table ON source_table.oid = constraint_record.conrelid
      JOIN pg_catalog.pg_namespace source_schema ON source_schema.oid = source_table.relnamespace
      JOIN pg_catalog.pg_class target_table ON target_table.oid = constraint_record.confrelid
      JOIN pg_catalog.pg_namespace target_schema ON target_schema.oid = target_table.relnamespace
      CROSS JOIN LATERAL unnest(constraint_record.conkey, constraint_record.confkey)
        AS column_pair(source_number, target_number)
      JOIN pg_catalog.pg_attribute source_column
        ON source_column.attrelid = source_table.oid
        AND source_column.attnum = column_pair.source_number
      JOIN pg_catalog.pg_attribute target_column
        ON target_column.attrelid = target_table.oid
        AND target_column.attnum = column_pair.target_number
      WHERE constraint_record.contype = 'f' AND source_schema.nspname = ANY($1)
        AND target_schema.nspname = ANY($1)
      ORDER BY source_schema.nspname, source_table.relname, source_column.attname,
               target_schema.nspname, target_table.relname, target_column.attname
      """,
      [schemas]
    )
    |> Enum.map(fn [schema, table, column, foreign_schema, foreign_table, foreign_column] ->
      %{
        schema: schema,
        table: table,
        column: column,
        foreign_schema: foreign_schema,
        foreign_table: foreign_table,
        foreign_column: foreign_column
      }
    end)
  end

  defp write_domain_outputs!(repo, schemas, domains_file, output_dir) do
    domains = load_domains!(domains_file)
    tables = fetch_tables(repo, schemas)
    columns = fetch_columns(repo, schemas)
    foreign_keys = fetch_foreign_keys(repo, schemas)
    validate_domains!(domains, tables)
    available_tables = MapSet.new(Enum.map(tables, & &1.name))

    Enum.each(domains, fn domain ->
      domain = %{
        domain
        | tables: Enum.filter(domain.tables, &MapSet.member?(available_tables, &1))
      }

      dot = generate_domain_dot(domain, tables, columns, foreign_keys)
      base = Path.join(output_dir, domain.id)
      write_outputs!(base <> ".dot", base <> ".svg", dot)
    end)
  end

  defp load_domains!(path) do
    {domains, _binding} = Code.eval_file(path)

    Enum.map(domains, fn domain ->
      %{
        id: to_string(Map.fetch!(domain, :id)),
        title: Map.fetch!(domain, :title),
        tables: Map.fetch!(domain, :tables),
        optional_tables: Map.get(domain, :optional_tables, [])
      }
    end)
  rescue
    error in [KeyError, MatchError] ->
      Mix.raise("invalid domain manifest #{path}: #{Exception.message(error)}")
  end

  defp validate_domains!(domains, tables) do
    assigned = domains |> Enum.flat_map(& &1.tables) |> MapSet.new()
    available = tables |> Enum.map(& &1.name) |> MapSet.new()

    duplicates =
      domains
      |> Enum.flat_map(& &1.tables)
      |> Enum.frequencies()
      |> Enum.filter(fn {_table, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))

    optional = domains |> Enum.flat_map(& &1.optional_tables) |> MapSet.new()

    unknown =
      MapSet.difference(assigned, available) |> MapSet.difference(optional) |> MapSet.to_list()

    unassigned = MapSet.difference(available, assigned) |> MapSet.to_list()

    if duplicates != [] or unknown != [] or unassigned != [] do
      Mix.raise(
        "domain manifest must assign each table exactly once; duplicates=#{inspect(duplicates)}, unknown=#{inspect(unknown)}, unassigned=#{inspect(unassigned)}"
      )
    end
  end

  @doc false
  def generate_domain_dot(domain, tables, columns, foreign_keys) do
    local = MapSet.new(domain.tables)
    table_schemas = Map.new(tables, &{&1.name, &1.schema})
    columns_by_table = Enum.group_by(columns, & &1.table)
    local_foreign_keys = Enum.filter(foreign_keys, &MapSet.member?(local, &1.table))

    external_tables =
      local_foreign_keys
      |> Enum.map(& &1.foreign_table)
      |> Enum.reject(&MapSet.member?(local, &1))
      |> Enum.uniq()
      |> Enum.sort()

    local_nodes =
      Enum.map(domain.tables, fn table ->
        domain_table_node(
          table,
          Map.fetch!(table_schemas, table),
          Map.get(columns_by_table, table, [])
        )
      end)

    external_nodes = Enum.map(external_tables, &external_table_node/1)

    edges =
      Enum.map(local_foreign_keys, fn fk ->
        cross_domain? = not MapSet.member?(local, fk.foreign_table)

        style =
          if cross_domain?,
            do: "color=\"#d97706\", style=\"dashed\", penwidth=1.5",
            else: "color=\"#64748b\""

        ~s(  "#{fk.table}" -> "#{fk.foreign_table}" [label="#{dot("#{fk.column} -> #{fk.foreign_column}")}", #{style}];)
      end)

    """
    digraph #{domain.id} {
      graph [rankdir=TB, bgcolor="white", pad=0.35, nodesep=0.6, ranksep=0.9, fontname="Helvetica"];
      node [shape=plain, fontname="Helvetica"];
      edge [fontname="Helvetica", fontsize=10, arrowsize=0.7];
      labelloc="t";
      label=< <B>#{html(domain.title)}</B><BR/><FONT POINT-SIZE="12">Local tables show every column. Amber dashed arrows cross a domain boundary.</FONT> >;

      subgraph cluster_local {
        label="#{dot(domain.title)}";
        color="#94a3b8";
        penwidth=1.5;
        style="rounded";
    #{Enum.join(local_nodes, "\n")}
      }

      subgraph cluster_external {
        label="External-domain references — other relationships are intentionally omitted";
        color="#cbd5e1";
        penwidth=1;
        style="rounded";
    #{Enum.join(external_nodes, "\n")}
      }

    #{Enum.join(edges, "\n")}
    }
    """
  end

  defp domain_table_node(table, schema, columns) do
    rows =
      Enum.map_join(columns, "", fn column ->
        key = if column.primary_key?, do: " PK", else: ""
        null = if column.nullable?, do: " NULL", else: " NOT NULL"

        "<TR><TD ALIGN=\"LEFT\">#{html(column.name)}#{key}</TD>" <>
          "<TD ALIGN=\"LEFT\">#{html(column.type)}#{null}</TD></TR>"
      end)

    """
      "#{table}" [label=<
        <TABLE BORDER="1" CELLBORDER="1" CELLSPACING="0" CELLPADDING="5" COLOR="#2563eb">
          <TR><TD BGCOLOR="#dbeafe" COLSPAN="2"><B>#{html(schema)}.#{html(table)}</B></TD></TR>
          #{rows}
        </TABLE>
      >];
    """
  end

  defp external_table_node(table) do
    """
      "#{table}" [label=<
        <TABLE BORDER="1" CELLBORDER="1" CELLSPACING="0" CELLPADDING="5" COLOR="#d97706">
          <TR><TD BGCOLOR="#fef3c7"><B>external: #{html(table)}</B></TD></TR>
          <TR><TD><FONT POINT-SIZE="10">other fields and relationships omitted</FONT></TD></TR>
        </TABLE>
      >];
    """
  end

  defp query!(repo, sql, params) do
    apply(Ecto.Adapters.SQL, :query!, [repo, sql, params]).rows
  end

  defp table_node(table, columns, prominent?) do
    {header_color, border_color, title_size, column_size, padding} =
      if prominent?,
        do: {"#bfdbfe", "#2563eb", 16, 12, 7},
        else: {"#e2e8f0", "#94a3b8", 12, 10, 4}

    rows =
      columns
      |> Enum.map(fn column ->
        key = if column.primary_key?, do: " PK", else: ""
        null = if column.nullable?, do: "", else: " NOT NULL"

        """
          <TR><TD ALIGN="LEFT"><FONT POINT-SIZE="#{column_size}">#{html(column.name)}#{key}</FONT></TD><TD ALIGN="LEFT"><FONT POINT-SIZE="#{column_size}">#{html(column.type)}#{null}</FONT></TD></TR>
        """
      end)
      |> Enum.join("")

    """
      "#{node_id(table.schema, table.name)}" [
        label=<
          <TABLE BORDER="#{if(prominent?, do: 2, else: 1)}" CELLBORDER="1" CELLPADDING="#{padding}" CELLSPACING="0" COLOR="#{border_color}">
            <TR><TD BGCOLOR="#{header_color}" COLSPAN="2"><FONT POINT-SIZE="#{title_size}"><B>#{html(table.schema)}.#{html(table.name)}</B></FONT></TD></TR>
    #{rows}      </TABLE>
        >
      ];
    """
  end

  defp foreign_key_edge(fk) do
    from = node_id(fk.schema, fk.table)
    to = node_id(fk.foreign_schema, fk.foreign_table)
    ~s(  "#{from}" -> "#{to}" [label="#{dot("#{fk.column} -> #{fk.foreign_column}")}"];)
  end

  defp write_outputs!(dot_path, svg_path, dot) do
    File.mkdir_p!(Path.dirname(dot_path))
    SchemaArtifactWriter.write_if_changed!(dot_path, dot)
    write_svg_if_stale!(svg_path, dot)
  end

  defp write_svg_if_stale!(svg_path, dot) do
    case File.read(svg_path) do
      {:ok, svg} ->
        if SchemaDiagramArtifacts.current?(svg, dot) do
          :unchanged
        else
          render_and_write_svg!(svg_path, dot, svg)
        end

      {:error, :enoent} ->
        render_and_write_svg!(svg_path, dot)

      {:error, reason} ->
        Mix.raise("could not read #{svg_path}: #{:file.format_error(reason)}")
    end
  end

  defp render_and_write_svg!(svg_path, dot, previous_svg \\ nil) do
    svg = render_svg!(dot)
    warn_if_renderer_changed(previous_svg, svg, svg_path)
    svg = SchemaDiagramArtifacts.stamp(svg, dot)
    SchemaArtifactWriter.write_if_changed!(svg_path, svg)
  end

  defp warn_if_renderer_changed(nil, _svg, _svg_path), do: :ok

  defp warn_if_renderer_changed(previous_svg, svg, svg_path) do
    previous_version = SchemaDiagramArtifacts.renderer_version(previous_svg)
    current_version = SchemaDiagramArtifacts.renderer_version(svg)

    if previous_version && current_version && previous_version != current_version do
      Mix.shell().error(
        "Warning: Graphviz renderer changed from #{previous_version} to #{current_version} " <>
          "while regenerating #{svg_path}; expect broad layout-only SVG changes."
      )
    end
  end

  @doc false
  def render_svg!(dot, opts \\ []) do
    token = System.unique_integer([:positive])
    source_path = Path.join(System.tmp_dir!(), "acceptance-schema-#{token}.dot")
    output_path = Path.join(System.tmp_dir!(), "acceptance-schema-#{token}.svg")
    command = Keyword.get(opts, :command, "dot")

    File.write!(source_path, dot)

    try do
      case System.cmd(
             command,
             ["-Tsvg", "-o", output_path, source_path],
             stderr_to_stdout: true
           ) do
        {_diagnostics, 0} -> File.read!(output_path)
        {output, status} -> Mix.raise("dot failed with status #{status}:\n#{output}")
      end
    after
      File.rm(source_path)
      File.rm(output_path)
    end
  end

  defp display_type("USER-DEFINED", udt_name), do: udt_name
  defp display_type("ARRAY", udt_name), do: udt_name
  defp display_type(data_type, _udt_name), do: data_type
  defp node_id(schema, table), do: "#{schema}.#{table}"

  defp html(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp dot(value),
    do: value |> to_string() |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
end

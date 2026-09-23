defmodule Mix.Tasks.Acceptance.SchemaCompare do
  @moduledoc """
  Renders a schema comparison between two revisions of the checked-in diagrams.

  The acceptance UI compares a run against the previous one, which only reaches
  back as far as the runs still held in the admin store. The DOT sources are
  committed alongside the application, so any two revisions can be compared —
  including releases that shipped before the comparison feature existed.

      mix acceptance.schema_compare --from v0.3.6 --to v0.3.7

  Writes one SVG per changed domain, plus the overview, into `--out`
  (default `tmp/schema-compare`). Domains that did not change are skipped, so
  an empty output directory means the two revisions share a schema.

  Additions are green, removals red, and changed types amber, all on one
  diagram.
  """

  use Mix.Task

  alias AcceptanceHarness.SchemaDiff

  @shortdoc "Compares checked-in schema diagrams between two git revisions"

  @switches [from: :string, to: :string, out: :string, domains_output: :string, output: :string]
  @default_out "tmp/schema-compare"

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, switches: @switches)

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    from = Keyword.get(opts, :from) || Mix.raise("--from <revision> is required")
    to = Keyword.get(opts, :to, "HEAD")
    out = Keyword.get(opts, :out, @default_out)

    config = Application.get_env(:acceptance_harness, :schema_diagram, [])
    overview = Keyword.get(opts, :output, Keyword.get(config, :output))

    domains =
      Keyword.get(opts, :domains_output) || Keyword.get(config, :domains_output) ||
        (overview && overview <> "_domains")

    File.mkdir_p!(out)

    written =
      sources(overview, domains)
      |> Enum.flat_map(&compare(&1, from, to, out))

    report(written, from, to, out)
  end

  # The overview is one file; domains are a directory of them. Both are compared
  # the same way once reduced to {name, repo-relative path}.
  defp sources(overview, domains) do
    overview_source = if overview, do: [{"overview", overview <> ".dot"}], else: []

    domain_sources =
      case domains && File.dir?(domains) do
        true ->
          domains
          |> File.ls!()
          |> Enum.filter(&String.ends_with?(&1, ".dot"))
          |> Enum.sort()
          |> Enum.map(&{Path.rootname(&1), Path.join(domains, &1)})

        _ ->
          []
      end

    overview_source ++ domain_sources
  end

  defp compare({name, path}, from, to, out) do
    with {:ok, before_dot} <- read_revision(from, path),
         {:ok, after_dot} <- read_revision(to, path),
         true <- SchemaDiff.any?(SchemaDiff.diff(before_dot, after_dot)),
         {:ok, svg} <- SchemaDiff.union_svg(before_dot, after_dot) do
      destination = Path.join(out, "#{name}.svg")
      File.write!(destination, svg)
      [destination]
    else
      {:error, :graphviz_unavailable} ->
        Mix.raise("Graphviz is required: install it and rerun (`dot` was not found)")

      _ ->
        []
    end
  end

  # A path absent from a revision is not an error: the domain was added or
  # removed, and nil compares as everything added or everything removed.
  defp read_revision(revision, path) do
    case System.cmd("git", ["show", "#{revision}:#{path}"], stderr_to_stdout: true) do
      {contents, 0} -> {:ok, contents}
      {_output, _code} -> {:ok, nil}
    end
  end

  defp report([], from, to, _out) do
    Mix.shell().info("No schema changes between #{from} and #{to}.")
  end

  defp report(written, from, to, out) do
    Mix.shell().info("Schema comparison #{from}..#{to} — #{length(written)} changed:")
    Enum.each(written, &Mix.shell().info("  #{&1}"))
    Mix.shell().info("Open them from #{Path.expand(out)}")
  end
end

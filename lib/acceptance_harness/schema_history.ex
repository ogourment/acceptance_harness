defmodule AcceptanceHarness.SchemaHistory do
  @moduledoc """
  Captures generated schema diagrams with an acceptance run and compares
  domain snapshots between runs.
  """

  @schema_domain_type "schema_domain"

  def capture!(opts \\ []) do
    config =
      Keyword.get(
        opts,
        :config,
        Application.get_env(:acceptance_harness, :schema_diagram, [])
      )

    evidence_dir = Keyword.get(opts, :evidence_dir, AcceptanceHarness.Config.evidence_dir())

    if configured?(config) do
      overview_artifacts(config, evidence_dir) ++ domain_artifacts(config, evidence_dir)
    else
      []
    end
  end

  def diff(current_artifacts, previous_artifacts) do
    current = domain_artifacts_by_id(current_artifacts)
    previous = domain_artifacts_by_id(previous_artifacts)

    current
    |> Map.keys()
    |> Kernel.++(Map.keys(previous))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn domain_id ->
      current_artifact = Map.get(current, domain_id)
      previous_artifact = Map.get(previous, domain_id)

      %{
        domain_id: domain_id,
        label: artifact_label(current_artifact || previous_artifact, domain_id),
        status: change_status(current_artifact, previous_artifact),
        current: current_artifact,
        previous: previous_artifact
      }
    end)
    |> Enum.reject(&is_nil(&1.status))
  end

  def overview_artifact(artifacts) do
    artifacts
    |> List.wrap()
    |> Enum.find(&(artifact_value(&1, "type") == "schema_overview"))
  end

  defp configured?(config) do
    is_list(config) and
      (present?(Keyword.get(config, :output)) or present?(Keyword.get(config, :domains_output)))
  end

  defp overview_artifacts(config, evidence_dir) do
    with output when is_binary(output) and output != "" <- Keyword.get(config, :output),
         true <- File.regular?(output <> ".dot"),
         true <- File.regular?(output <> ".svg") do
      dot_path = "schema/overview.dot"
      svg_path = "schema/overview.svg"
      copy!(output <> ".dot", evidence_dir, dot_path)
      copy!(output <> ".svg", evidence_dir, svg_path)

      [
        %{
          "type" => "schema_overview",
          "label" => "Complete schema",
          "dot_path" => dot_path,
          "path" => svg_path,
          "sha256" => file_sha256(output <> ".dot")
        }
      ]
    else
      _ -> []
    end
  end

  defp domain_artifacts(config, evidence_dir) do
    with output when is_binary(output) and output != "" <- Keyword.get(config, :domains_output),
         domains_file when is_binary(domains_file) and domains_file != "" <-
           Keyword.get(config, :domains_file) do
      domains_file
      |> load_domains!()
      |> Enum.map(fn domain ->
        id = domain |> Map.fetch!(:id) |> to_string() |> safe_domain_id!()
        title = domain |> Map.fetch!(:title) |> to_string()
        source_base = Path.join(output, id)
        dot_path = "schema/domains/#{id}.dot"
        svg_path = "schema/domains/#{id}.svg"

        require_file!(source_base <> ".dot", id)
        require_file!(source_base <> ".svg", id)
        copy!(source_base <> ".dot", evidence_dir, dot_path)
        copy!(source_base <> ".svg", evidence_dir, svg_path)

        %{
          "type" => @schema_domain_type,
          "domain_id" => id,
          "label" => title,
          "dot_path" => dot_path,
          "path" => svg_path,
          "sha256" => file_sha256(source_base <> ".dot")
        }
      end)
    else
      _ -> []
    end
  end

  defp load_domains!(path) do
    {domains, _binding} = Code.eval_file(path)

    if is_list(domains) do
      domains
    else
      raise ArgumentError, "#{path} must return a list of schema domains"
    end
  end

  defp safe_domain_id!(id) do
    if Regex.match?(~r/\A[a-z0-9][a-z0-9_-]*\z/, id) do
      id
    else
      raise ArgumentError, "unsafe schema domain id: #{inspect(id)}"
    end
  end

  defp require_file!(path, domain_id) do
    unless File.regular?(path) do
      raise ArgumentError, "schema domain #{domain_id} is missing generated artifact #{path}"
    end
  end

  defp copy!(source, evidence_dir, relative_path) do
    destination = Path.join(evidence_dir, relative_path)
    File.mkdir_p!(Path.dirname(destination))
    File.cp!(source, destination)
  end

  defp file_sha256(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp domain_artifacts_by_id(artifacts) do
    artifacts
    |> List.wrap()
    |> Enum.filter(&(artifact_value(&1, "type") == @schema_domain_type))
    |> Map.new(fn artifact -> {artifact_value(artifact, "domain_id"), artifact} end)
  end

  defp change_status(nil, nil), do: nil
  defp change_status(current, nil) when not is_nil(current), do: "new"
  defp change_status(nil, previous) when not is_nil(previous), do: "removed"

  defp change_status(current, previous) do
    if artifact_value(current, "sha256") == artifact_value(previous, "sha256"),
      do: nil,
      else: "changed"
  end

  defp artifact_label(artifact, fallback) do
    artifact_value(artifact, "label") || fallback
  end

  defp artifact_value(artifact, key) when is_map(artifact) do
    Map.get(artifact, key) || Map.get(artifact, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(artifact, key)
  end

  defp present?(value), do: is_binary(value) and value != ""

  @doc """
  Renders one comparison diagram per changed domain.

  Reads each domain's DOT source for both runs and produces a single diagram
  with additions green and removals red. Domains whose sources cannot be read,
  or hosts without Graphviz, are simply absent from the result so the caller
  falls back to the separate before/after diagrams rather than showing nothing.
  """
  @spec union_diagrams(list(), String.t(), String.t() | nil, keyword()) :: %{
          optional(String.t()) => String.t()
        }
  def union_diagrams(changes, current_run_id, previous_run_id, opts \\ []) do
    Enum.reduce(changes, %{}, fn change, acc ->
      with {:ok, current_source} <- read_source(current_run_id, change.current, opts),
           {:ok, previous_source} <- read_source(previous_run_id, change.previous, opts),
           {:ok, svg} <- AcceptanceHarness.SchemaDiff.union_svg(previous_source, current_source) do
        Map.put(acc, change.domain_id, svg)
      else
        _ -> acc
      end
    end)
  end

  # A brand-new or fully removed domain has no counterpart, which is not a
  # failure: nil compares as "everything added" or "everything removed".
  defp read_source(_run_id, nil, _opts), do: {:ok, nil}
  defp read_source(nil, _artifact, _opts), do: {:ok, nil}

  # Runs captured before the DOT was archived have only the rendered SVG, which
  # `SchemaDiff.parse/1` reads just as well. Falling back to it is what lets a
  # comparison reach back past the release that started keeping the source.
  defp read_source(run_id, artifact, opts) do
    ["dot_path", "path"]
    |> Enum.map(&artifact_value(artifact, &1))
    |> Enum.find_value(:error, fn
      nil -> nil
      path -> read_artifact(run_id, path, opts)
    end)
  end

  defp read_artifact(run_id, path, opts) do
    case AcceptanceHarness.AdminStore.artifact_location(run_id, path, opts) do
      {:file, local} ->
        case File.read(local) do
          {:ok, contents} -> {:ok, contents}
          _ -> nil
        end

      _ ->
        nil
    end
  end
end

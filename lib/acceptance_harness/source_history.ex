defmodule AcceptanceHarness.SourceHistory do
  @moduledoc false

  alias AcceptanceHarness.Config

  def capture!(scenarios) do
    Enum.map_reduce(scenarios, %{}, fn scenario, artifacts ->
      metadata = Map.get(scenario, :metadata, %{})

      with {:ok, contents, extension} <- AcceptanceHarness.ScenarioSource.read(metadata) do
        checksum = Base.encode16(:crypto.hash(:sha256, contents), case: :lower)
        relative_path = Path.join("sources", checksum <> extension)
        destination = Path.join(Config.evidence_dir(), relative_path)

        File.mkdir_p!(Path.dirname(destination))
        File.write!(destination, contents)

        scenario =
          put_in(scenario, [:metadata, "source_snapshot_path"], relative_path)

        artifact = %{
          type: "scenario_source",
          path: relative_path,
          checksum: checksum
        }

        {scenario, Map.put(artifacts, relative_path, artifact)}
      else
        _ -> {scenario, artifacts}
      end
    end)
    |> then(fn {scenarios, artifacts} ->
      {scenarios, artifacts |> Map.values() |> Enum.sort_by(& &1.path)}
    end)
  end
end

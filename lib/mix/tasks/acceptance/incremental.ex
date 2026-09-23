defmodule Mix.Tasks.Acceptance.Incremental do
  @moduledoc "Builds a conservative fast/remaining acceptance selection manifest."
  use Mix.Task

  @shortdoc "Selects fast and remaining acceptance scenarios"
  @switches [
    scenarios: :string,
    config: :string,
    commits: :string,
    changes: :string,
    output: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, [], []} = OptionParser.parse(args, strict: @switches)
    config = opts |> Keyword.fetch!(:config) |> decode!()

    plan =
      AcceptanceHarness.IncrementalSelection.plan(opts |> Keyword.fetch!(:scenarios) |> decode!(),
        aliases: Map.get(config, "aliases", %{}),
        mandatory_ids: Map.get(config, "mandatory_ids", []),
        path_rules: Map.get(config, "path_rules", []),
        full_suite_paths: Map.get(config, "full_suite_paths", []),
        commit_messages: lines(Keyword.get(opts, :commits)),
        changed_paths: lines(Keyword.get(opts, :changes))
      )

    output = Keyword.fetch!(opts, :output)
    File.mkdir_p!(Path.dirname(output))
    File.write!(output, Jason.encode!(plan, pretty: true))
    Mix.shell().info("Acceptance selection: #{plan.mode} (#{plan.reason})")
  rescue
    error in KeyError -> Mix.raise("missing required option: #{Exception.message(error)}")
  end

  defp decode!(path), do: path |> File.read!() |> Jason.decode!()
  defp lines(nil), do: []
  defp lines(path), do: path |> File.read!() |> String.split("\n", trim: true)
end

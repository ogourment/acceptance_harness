defmodule Mix.Tasks.Acceptance.Assemble do
  @moduledoc "Assembles phased acceptance evidence by stable scenario ID."
  use Mix.Task

  @shortdoc "Assembles phased acceptance evidence"

  @impl Mix.Task
  def run(args) do
    {opts, sources, []} = OptionParser.parse(args, strict: [output: :string, plan: :string])
    output = Keyword.fetch!(opts, :output)
    plan = opts |> Keyword.fetch!(:plan) |> File.read!() |> Jason.decode!()

    case AcceptanceHarness.EvidenceAssembly.assemble!(
           sources,
           output,
           Map.fetch!(plan, "all_ids")
         ) do
      :ok ->
        Mix.shell().info("Assembled #{length(sources)} acceptance evidence phase(s).")

      {:error, {:missing_scenarios, ids}} ->
        Mix.raise("missing acceptance scenarios: #{Enum.join(ids, ", ")}")
    end
  end
end

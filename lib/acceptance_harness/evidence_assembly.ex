defmodule AcceptanceHarness.EvidenceAssembly do
  @moduledoc "Assembles phased evidence into one stable-scenario report."

  def assemble!(source_dirs, output_dir, expected_ids) do
    reports = Enum.map(source_dirs, &read_report!/1)
    scenarios = merge_scenarios(reports)
    actual_ids = MapSet.new(Enum.map(scenarios, &Map.fetch!(&1, "id")))
    missing = expected_ids |> MapSet.new() |> MapSet.difference(actual_ids) |> Enum.sort()

    File.rm_rf!(output_dir)
    File.mkdir_p!(output_dir)
    copy_artifacts!(source_dirs, output_dir)

    assembled =
      reports
      |> List.last()
      |> Map.put("schema_version", "acceptance_harness.evidence.v1")
      |> Map.put(
        "generated_at",
        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      )
      |> Map.put("scenarios", order_scenarios(scenarios, expected_ids))
      |> Map.put("pending_steps", Enum.flat_map(reports, &Map.get(&1, "pending_steps", [])))
      |> Map.put(
        "pending_scenarios",
        Enum.flat_map(reports, &Map.get(&1, "pending_scenarios", []))
      )
      |> put_in(["run", "phases"], Enum.map(reports, &Map.get(&1, "run", %{})))

    File.write!(Path.join(output_dir, "evidence.json"), Jason.encode!(assembled, pretty: true))
    File.write!(Path.join(output_dir, "e2e.md"), markdown(assembled, missing))
    File.cp!(Path.join(output_dir, "e2e.md"), Path.join(output_dir, "journeys.md"))

    if missing == [], do: :ok, else: {:error, {:missing_scenarios, missing}}
  end

  defp read_report!(dir), do: dir |> Path.join("evidence.json") |> File.read!() |> Jason.decode!()

  defp merge_scenarios(reports) do
    reports
    |> Enum.flat_map(&Map.get(&1, "scenarios", []))
    |> Enum.reduce(%{}, fn scenario, acc -> Map.put(acc, Map.fetch!(scenario, "id"), scenario) end)
    |> Map.values()
  end

  defp order_scenarios(scenarios, expected_ids) do
    order = expected_ids |> Enum.with_index() |> Map.new()
    Enum.sort_by(scenarios, &Map.get(order, Map.fetch!(&1, "id"), 1_000_000))
  end

  defp copy_artifacts!(source_dirs, output_dir) do
    Enum.each(source_dirs, fn source ->
      source
      |> File.ls!()
      |> Enum.reject(&(&1 in ["evidence.json", "e2e.md", "journeys.md", "status.env"]))
      |> Enum.each(fn entry ->
        from = Path.join(source, entry)
        to = Path.join(output_dir, entry)

        if File.dir?(from),
          do: File.cp_r!(from, to, on_conflict: fn _source, _destination -> true end),
          else: File.cp!(from, to)
      end)
    end)
  end

  defp markdown(report, missing) do
    scenarios = Map.get(report, "scenarios", [])
    counts = Enum.frequencies_by(scenarios, &Map.get(&1, "status", "unknown"))

    """
    # #{Map.get(report, "title", "Acceptance evidence")}

    - Generated: **#{Map.get(report, "generated_at")}**
    - App version: **#{get_in(report, ["app", "version"])}**
    - Commit: **#{get_in(report, ["app", "commit"])}**
    - Phases assembled: **#{length(get_in(report, ["run", "phases"]) || [])}**

    ## Scenario Summary

    - Success: **#{Map.get(counts, "success", 0)}**
    - Failure: **#{Map.get(counts, "failure", 0)}**
    - Ignored: **#{Map.get(counts, "ignored", 0)}**
    - Skipped: **#{Map.get(counts, "skipped", 0)}**
    - Missing: **#{length(missing)}**

    #{Enum.map_join(scenarios, "\n", &scenario_markdown/1)}
    #{if missing == [], do: "", else: "\n## Missing scenarios\n\n" <> Enum.map_join(missing, "\n", &"- ❌ `#{&1}`")}
    """
  end

  defp scenario_markdown(scenario) do
    icon = if Map.get(scenario, "status") == "success", do: "✅", else: "❌"

    steps =
      scenario
      |> Map.get("steps", [])
      |> Enum.map_join("\n", fn step ->
        screenshot = get_in(step, ["screenshot", "path"])

        image =
          if is_binary(screenshot),
            do: "\n\n![#{Map.get(step, "title") || "Evidence"}](#{screenshot})",
            else: ""

        "### #{Map.get(step, "sequence", "-")} - #{Map.get(step, "title", "Step")}\n\n#{Map.get(step, "description", "")}#{image}"
      end)

    "## #{icon} Scenario: #{Map.get(scenario, "title", scenario["id"])}\n\n`#{scenario["id"]}` · **#{scenario["status"]}**\n\n#{steps}"
  end
end

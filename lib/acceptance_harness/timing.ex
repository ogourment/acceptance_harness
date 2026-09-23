defmodule AcceptanceHarness.Timing do
  @moduledoc false

  def run_metrics(run) do
    timing = value(run, :timing) || %{}

    [
      metric(
        "Pipeline to evidence",
        value(timing, :pipeline_age_ms),
        "pipeline created → evidence finalized"
      ),
      job_pending_metric(timing),
      metric("Runner queue", value(timing, :runner_queue_ms), "provider-reported runner queue"),
      metric("Evidence run", value(timing, :wall_time_ms), "collector wall time"),
      metric("Documented steps", value(timing, :documented_step_ms), "captured evidence actions"),
      metric("Setup / assertions", value(timing, :undocumented_ms), "work outside captured steps")
    ]
  end

  defp job_pending_metric(timing) do
    metadata = value(timing, :job_timing) || %{}

    metric =
      metric("Evidence job pending", value(timing, :job_wait_ms), "job created → runner started")

    cond do
      is_integer(metric.duration_ms) ->
        metric

      value(metadata, :status) == "not_applicable" ->
        %{metric | value: "Not applicable", help: value(metadata, :reason)}

      value(metadata, :reason) ->
        %{metric | help: metric.help <> " · " <> value(metadata, :reason)}

      true ->
        metric
    end
  end

  def scenario_metrics(scenario) do
    [
      metric("Elapsed", value(scenario, :duration_ms), "scenario total"),
      metric("Steps", value(scenario, :documented_step_ms), "captured evidence"),
      metric("Setup / assertions", value(scenario, :undocumented_ms), "uncaptured work")
    ]
  end

  def tag_summary(scenarios) do
    scenarios
    |> Enum.flat_map(fn scenario ->
      tags = facet_values(value(scenario, :tags))
      tags = if tags == [], do: ["(untagged)"], else: tags

      Enum.map(tags, fn tag ->
        {tag, length(value(scenario, :steps) || []), value(scenario, :documented_step_ms) || 0}
      end)
    end)
    |> Enum.reduce(%{}, fn {tag, steps, duration_ms}, acc ->
      Map.update(
        acc,
        tag,
        %{tag: tag, scenarios: 1, steps: steps, duration_ms: duration_ms},
        fn row ->
          %{
            row
            | scenarios: row.scenarios + 1,
              steps: row.steps + steps,
              duration_ms: row.duration_ms + duration_ms
          }
        end
      )
    end)
    |> Map.values()
    |> Enum.sort_by(&{-&1.duration_ms, -&1.scenarios, &1.tag})
  end

  def step_label(step, scenario_status \\ nil) do
    case value(value(step, :metadata) || %{}, :duration_ms) do
      duration when is_integer(duration) -> duration_label(duration)
      _ when scenario_status in ["ignored", "skipped", "pending", "running"] -> "Not executed"
      _ -> "Unavailable"
    end
  end

  def duration_label(nil), do: "Unavailable"

  def duration_label(milliseconds) when is_integer(milliseconds) and milliseconds < 1_000,
    do: "#{milliseconds} ms"

  def duration_label(milliseconds) when is_integer(milliseconds) and milliseconds < 60_000 do
    seconds = Float.round(milliseconds / 1_000, 1)
    "#{format_decimal(seconds)} s"
  end

  def duration_label(milliseconds) when is_integer(milliseconds) do
    total_seconds = round(milliseconds / 1_000)
    minutes = div(total_seconds, 60)
    seconds = rem(total_seconds, 60)
    if seconds == 0, do: "#{minutes} min", else: "#{minutes} min #{seconds} s"
  end

  defp metric(label, duration_ms, help),
    do: %{label: label, duration_ms: duration_ms, value: duration_label(duration_ms), help: help}

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp value(_map, _key), do: nil

  defp facet_values(values) when is_list(values),
    do: values |> Enum.map(&to_string/1) |> Enum.reject(&(&1 in ["", "-"]))

  defp facet_values(_values), do: []

  defp format_decimal(value) do
    if value == trunc(value), do: Integer.to_string(trunc(value)), else: Float.to_string(value)
  end
end

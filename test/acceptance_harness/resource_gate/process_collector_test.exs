defmodule AcceptanceHarness.ResourceGate.ProcessCollectorTest do
  use ExUnit.Case, async: false

  alias AcceptanceHarness.ResourceGate
  alias AcceptanceHarness.ResourceGate.ProcessCollector

  test "samples a surviving local process for GNOME or iOS Simulator scenarios" do
    readings = start_supervised!({Agent, fn -> [100, 120, 110] end})
    rss_reader = &next_reading(readings, &1)

    assert {:ok, state} =
             ProcessCollector.start(
               pid: 42,
               platform: :ios_simulator,
               max_retained_growth_bytes: 64,
               rss_reader: rss_reader,
               handle_reader: fn _pid -> nil end
             )

    assert {:ok, state} = ProcessCollector.sample(state)
    assert {:ok, result} = ProcessCollector.finish(state)
    assert result.process_survived
    assert result.platform == :ios_simulator
    assert result.sample_count == 3
    assert result.peak_bytes >= result.baseline_bytes
    assert result.peak_bytes >= result.settled_bytes
    assert ResourceGate.evaluate(result).status == :passed
  end

  test "never substitutes host RSS collection for a physical iOS collector" do
    assert {:skip, "physical iOS requires an Instruments collector"} =
             ProcessCollector.start(
               pid: 42,
               platform: :ios_physical,
               max_retained_growth_bytes: 1
             )
  end

  test "records target termination as a failed gate" do
    readings = start_supervised!({Agent, fn -> [100, :unavailable] end})
    rss_reader = &next_reading(readings, &1)

    assert {:ok, state} =
             ProcessCollector.start(
               pid: 42,
               platform: :gnome,
               max_retained_growth_bytes: 1_024,
               rss_reader: rss_reader,
               handle_reader: fn _pid -> nil end
             )

    assert {:ok, result} = ProcessCollector.finish(state)
    refute result.process_survived
    assert ResourceGate.evaluate(result).status == :failed
  end

  defp next_reading(agent, _pid) do
    Agent.get_and_update(agent, fn
      [value | rest] ->
        result = if is_integer(value), do: {:ok, value}, else: {:error, :process_unavailable}
        {result, rest}

      [] ->
        {{:error, :process_unavailable}, []}
    end)
  end
end

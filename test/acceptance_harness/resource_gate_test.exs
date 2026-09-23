defmodule AcceptanceHarness.ResourceGateTest do
  use ExUnit.Case, async: true

  alias AcceptanceHarness.ResourceGate

  test "passes a surviving process within retained-memory and handle budgets" do
    result = valid_result()

    assert %{status: :passed, reasons: []} = ResourceGate.evaluate(result)
    assert ResourceGate.verify!(result) == result
  end

  test "fails process termination, retained growth, handle growth, and a leak check" do
    result = %{
      valid_result()
      | process_survived: false,
        termination_reason: "jetsam",
        settled_bytes: 140,
        settled_handle_count: 8,
        leak_check: :failed
    }

    assert %{status: :failed, reasons: reasons} = ResourceGate.evaluate(result)
    assert "target process terminated: jetsam" in reasons
    assert "retained memory growth 40 bytes exceeds budget 10 bytes" in reasons
    assert "handle growth 3 exceeds allowance 1" in reasons
    assert "platform leak check failed" in reasons

    assert_raise ResourceGate.Error, ~r/scenario resource gate failed/, fn ->
      ResourceGate.verify!(result)
    end
  end

  test "keeps unavailable collection explicitly skipped rather than passed" do
    result = %{
      collector_status: :skipped,
      skip_reason: "Instruments is unavailable on this runner"
    }

    assert %{status: :skipped, reasons: ["Instruments is unavailable on this runner"]} =
             ResourceGate.evaluate(result)

    assert_raise ResourceGate.Error, ~r/resource gate skipped/, fn ->
      ResourceGate.verify!(result)
    end
  end

  test "rejects incomplete measurements" do
    assert %{status: :failed, reasons: reasons} =
             ResourceGate.evaluate(%{process_survived: true, leak_check: :passed})

    assert Enum.any?(reasons, &String.starts_with?(&1, "missing or invalid"))
  end

  test "requires an explicit budget, positive samples, and coherent memory measurements" do
    result = %{valid_result() | sample_count: 0, peak_bytes: 90}
    result = Map.delete(result, :max_retained_growth_bytes)

    assert %{status: :failed, reasons: reasons} = ResourceGate.evaluate(result)
    assert Enum.any?(reasons, &String.contains?(&1, "max_retained_growth_bytes"))
    assert "sample_count must be positive" in reasons
    assert "peak_bytes must not be lower than baseline_bytes or settled_bytes" in reasons
  end

  defp valid_result do
    %{
      collector_status: :collected,
      baseline_bytes: 100,
      peak_bytes: 180,
      settled_bytes: 105,
      sample_count: 20,
      process_survived: true,
      termination_reason: nil,
      max_retained_growth_bytes: 10,
      baseline_handle_count: 5,
      settled_handle_count: 6,
      max_handle_growth: 1,
      leak_check: :passed
    }
  end
end

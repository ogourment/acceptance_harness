defmodule AcceptanceHarness.ResourceGate do
  @moduledoc """
  Evaluates normalized process-resource evidence at scenario completion.

  Collectors are deliberately pluggable: an iOS adapter may use Instruments
  and jetsam evidence, while Linux adapters may use `/proc` RSS and descriptor
  counts. The evaluator never treats missing or skipped collection as a pass.
  """

  @required_integer_fields ~w(
    baseline_bytes
    peak_bytes
    settled_bytes
    sample_count
    max_retained_growth_bytes
  )a

  alias AcceptanceHarness.ResourceGate.Error

  @type status :: :passed | :failed | :skipped
  @type evaluation :: %{status: status(), reasons: [String.t()], result: map()}

  @spec evaluate(map()) :: evaluation()
  def evaluate(result) when is_map(result) do
    reasons = validation_reasons(result)

    status =
      cond do
        Map.get(result, :collector_status) == :skipped -> :skipped
        reasons == [] -> :passed
        true -> :failed
      end

    %{status: status, reasons: reasons, result: result}
  end

  @spec verify!(map()) :: map()
  def verify!(result) do
    case evaluate(result) do
      %{status: :passed} ->
        result

      %{status: status, reasons: reasons} ->
        raise Error,
          status: status,
          reasons: reasons,
          message: "scenario resource gate #{status}: #{Enum.join(reasons, "; ")}"
    end
  end

  defp validation_reasons(%{collector_status: :skipped} = result) do
    case Map.get(result, :skip_reason) do
      reason when is_binary(reason) and byte_size(reason) > 0 -> [reason]
      _ -> ["resource collection was skipped without a reason"]
    end
  end

  defp validation_reasons(result) do
    missing = Enum.reject(@required_integer_fields, &valid_nonnegative_integer?(result, &1))
    reasons = if missing == [], do: [], else: ["missing or invalid #{Enum.join(missing, ", ")}"]

    reasons =
      if is_integer(Map.get(result, :sample_count)) and Map.get(result, :sample_count) < 1,
        do: reasons ++ ["sample_count must be positive"],
        else: reasons

    reasons =
      if valid_memory_order?(result),
        do: reasons,
        else: reasons ++ ["peak_bytes must not be lower than baseline_bytes or settled_bytes"]

    reasons =
      if Map.get(result, :process_survived) == true,
        do: reasons,
        else: reasons ++ [termination_reason(result)]

    reasons = budget_reasons(result, reasons)
    reasons = handle_reasons(result, reasons)
    leak_reasons(result, reasons)
  end

  defp valid_nonnegative_integer?(result, key), do: is_integer(result[key]) and result[key] >= 0

  defp valid_memory_order?(result) do
    with baseline when is_integer(baseline) <- Map.get(result, :baseline_bytes),
         peak when is_integer(peak) <- Map.get(result, :peak_bytes),
         settled when is_integer(settled) <- Map.get(result, :settled_bytes) do
      peak >= baseline and peak >= settled
    else
      _ -> true
    end
  end

  defp termination_reason(result) do
    case Map.get(result, :termination_reason) do
      reason when is_binary(reason) and byte_size(reason) > 0 ->
        "target process terminated: #{reason}"

      _ ->
        "target process did not survive"
    end
  end

  defp budget_reasons(result, reasons) do
    with settled when is_integer(settled) <- Map.get(result, :settled_bytes),
         baseline when is_integer(baseline) <- Map.get(result, :baseline_bytes),
         budget when is_integer(budget) and budget >= 0 <-
           Map.get(result, :max_retained_growth_bytes),
         growth <- settled - baseline,
         true <- growth > budget do
      reasons ++ ["retained memory growth #{growth} bytes exceeds budget #{budget} bytes"]
    else
      _ -> reasons
    end
  end

  defp handle_reasons(result, reasons) do
    with baseline when is_integer(baseline) <- Map.get(result, :baseline_handle_count),
         settled when is_integer(settled) <- Map.get(result, :settled_handle_count),
         allowance when is_integer(allowance) and allowance >= 0 <-
           Map.get(result, :max_handle_growth),
         growth <- settled - baseline,
         true <- growth > allowance do
      reasons ++ ["handle growth #{growth} exceeds allowance #{allowance}"]
    else
      _ -> reasons
    end
  end

  defp leak_reasons(%{leak_check: :failed} = result, reasons) do
    reasons ++ [Map.get(result, :leak_reason, "platform leak check failed")]
  end

  defp leak_reasons(%{leak_check: status}, reasons) when status in [:passed, :unavailable],
    do: reasons

  defp leak_reasons(_result, reasons),
    do: reasons ++ ["leak_check must be passed, unavailable, or failed"]
end

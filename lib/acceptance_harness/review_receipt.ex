defmodule AcceptanceHarness.ReviewReceipt do
  @moduledoc """
  Portable, project-scoped human review receipts. A receipt is visibility
  evidence, not an approval or a unique-person count. Environment is provenance,
  not part of a target's revision, so promotion preserves review coverage.
  """
  @fields ~w(id project target revision environment run_id source viewed_at)
  @sources ~w(human automated unattributed)

  def new(attrs, session) when is_map(attrs) and is_binary(session) do
    attrs = Map.take(attrs, @fields)
    id = fingerprint([session, attrs["project"], attrs["target"], attrs["revision"]])
    validate(Map.put(attrs, "id", id))
  end

  def validate(attrs) when is_map(attrs) do
    with true <- Enum.all?(@fields, &(is_binary(attrs[&1]) and byte_size(attrs[&1]) in 1..512)),
         true <- attrs["source"] in @sources,
         true <- Regex.match?(~r/^[a-f0-9]{64}$/, attrs["id"]),
         {:ok, _, _} <- DateTime.from_iso8601(attrs["viewed_at"]) do
      {:ok, Map.take(attrs, @fields)}
    else
      _ -> {:error, :invalid_receipt}
    end
  end

  def validate(_), do: {:error, :invalid_receipt}

  def fingerprint(value),
    do: :crypto.hash(:sha256, Jason.encode!(canonical(value))) |> Base.encode16(case: :lower)

  # Deterministic across JSON producers and persistence adapters.
  defp canonical(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {to_string(key), canonical(item)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value

  def summarize(receipts, project, target, revision) do
    rows =
      receipts
      |> Enum.filter(&(&1["project"] == project and &1["target"] == target))
      |> Enum.uniq_by(& &1["id"])

    human = Enum.filter(rows, &(&1["source"] == "human"))
    current = Enum.filter(human, &(&1["revision"] == revision))

    %{
      reads: length(current),
      historical_reads: length(human),
      environments: Enum.frequencies_by(current, & &1["environment"]),
      automated: Enum.count(rows, &(&1["source"] == "automated")),
      state:
        cond do
          current != [] -> "reviewed"
          human != [] -> "changed_unreviewed"
          true -> "no_recorded_review"
        end
    }
  end
end

defmodule AcceptanceHarnessWeb.RunFilter do
  @moduledoc """
  Filter state for the run overview: organizational value stream and
  capability, evidence facets (device, language, user/role, tag), and full-text
  search. The whole state is one JSON object carried in the
  `filter` URL query parameter, so filtered views are shareable links.
  """

  @keys ~w(stream capability device language user tag q)

  def keys, do: @keys

  @doc "Parses the `filter` query param (JSON) into a clean filter map."
  def parse(params) when is_map(params) do
    params
    |> Map.get("filter", "")
    |> decode()
    |> clean()
  end

  @doc "Builds a filter map from flat form params (same keys, blank = unset)."
  def from_form(params) when is_map(params) do
    clean(params)
  end

  @doc "Encodes the filter as the `filter` query param value, or nil if empty."
  def encode(filter) when filter == %{}, do: nil
  def encode(filter), do: Jason.encode!(filter)

  @doc "Store options for `AdminStore.list_scenarios/2`."
  def to_store_opts(filter) do
    [
      value_stream: filter["stream"],
      capability: filter["capability"],
      device: filter["device"],
      language: filter["language"],
      user: filter["user"],
      tag: filter["tag"],
      search: filter["q"]
    ]
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
  end

  defp decode(value) when is_binary(value) and value != "" do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode(_value), do: %{}

  defp clean(map) do
    map
    |> Map.take(@keys)
    |> Enum.reject(fn {_key, value} -> !is_binary(value) or String.trim(value) == "" end)
    |> Map.new(fn {key, value} -> {key, String.trim(value)} end)
  end
end

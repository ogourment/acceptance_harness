defmodule AcceptanceHarness.IncrementalSelection do
  @moduledoc """
  Builds a fail-safe two-phase acceptance plan from canonical scenario metadata.

  Commit markers and changed-path mappings may only add scenarios. Missing,
  unknown, or ambiguous impact returns a full-suite plan.
  """

  @marker ~r/(?:^|\s)#([a-z][a-z0-9_-]*)\b/u

  def plan(scenarios, opts) when is_list(scenarios) and is_list(opts) do
    scenarios = Enum.map(scenarios, &normalize_scenario!/1)
    aliases = normalize_aliases(Keyword.get(opts, :aliases, %{}))
    known_areas = known_areas(scenarios, aliases)
    markers = extract_markers(Keyword.get(opts, :commit_messages, []))
    changed_paths = Keyword.get(opts, :changed_paths, [])
    path_rules = Keyword.get(opts, :path_rules, [])
    full_suite_paths = Keyword.get(opts, :full_suite_paths, [])
    mandatory_ids = MapSet.new(Keyword.get(opts, :mandatory_ids, []))

    with :ok <- validate_scenarios(scenarios),
         :ok <- validate_markers(markers, known_areas),
         {:ok, path_areas} <- areas_for_paths(changed_paths, path_rules, full_suite_paths),
         areas <- MapSet.union(resolve_markers(markers, aliases), path_areas),
         :ok <- ensure_impact(markers, changed_paths, areas) do
      selected_ids =
        scenarios
        |> Enum.filter(&(scenario_matches?(&1, areas) or MapSet.member?(mandatory_ids, &1.id)))
        |> Enum.map(& &1.id)
        |> MapSet.new()

      if MapSet.size(selected_ids) == 0,
        do: full_plan(scenarios, "no scenarios matched the declared impact"),
        else: phased_plan(scenarios, selected_ids, areas, markers, changed_paths)
    else
      {:full, reason} -> full_plan(scenarios, reason)
    end
  end

  defp normalize_scenario!(scenario) do
    metadata = value(scenario, :metadata, %{})

    %{
      id: required_string!(scenario, :id),
      source_file: required_string!(scenario, :source_file),
      tags: value(scenario, :tags, []) |> List.wrap() |> Enum.map(&normalize_area/1),
      roles: value(scenario, :roles, []) |> List.wrap() |> Enum.map(&normalize_area/1),
      capability: normalize_area(value(metadata, :capability, "")),
      value_stream: normalize_area(value(metadata, :value_stream, ""))
    }
  end

  defp required_string!(map, key) do
    case value(map, key, nil) do
      value when is_binary(value) and value != "" -> value
      _ -> raise ArgumentError, "scenario #{inspect(key)} must be a non-empty string"
    end
  end

  defp value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp validate_scenarios(scenarios) do
    ids = Enum.map(scenarios, & &1.id)

    if Enum.uniq(ids) == ids,
      do: :ok,
      else: {:full, "scenario registry contains duplicate stable IDs"}
  end

  defp extract_markers(messages) do
    messages
    |> List.wrap()
    |> Enum.flat_map(&Regex.scan(@marker, &1, capture: :all_but_first))
    |> List.flatten()
    |> Enum.map(&normalize_area/1)
    |> MapSet.new()
  end

  defp normalize_aliases(aliases),
    do: Map.new(aliases, fn {name, area} -> {normalize_area(name), normalize_area(area)} end)

  defp known_areas(scenarios, aliases) do
    scenario_areas = scenarios |> Enum.flat_map(&areas/1) |> MapSet.new()
    MapSet.union(scenario_areas, aliases |> Map.keys() |> MapSet.new())
  end

  defp validate_markers(markers, known_areas) do
    unknown = MapSet.difference(markers, known_areas)

    if MapSet.size(unknown) == 0,
      do: :ok,
      else: {:full, "unknown commit area marker(s): #{unknown |> Enum.sort() |> Enum.join(", ")}"}
  end

  defp resolve_markers(markers, aliases),
    do: markers |> Enum.map(&Map.get(aliases, &1, &1)) |> MapSet.new()

  defp areas_for_paths([], _rules, _full_suite_paths), do: {:ok, MapSet.new()}

  defp areas_for_paths(paths, rules, full_suite_paths) do
    Enum.reduce_while(paths, {:ok, MapSet.new()}, fn path, {:ok, selected} ->
      cond do
        Enum.any?(full_suite_paths, &path_matches?(path, &1)) ->
          {:halt, {:full, "shared-impact path requires the full suite: #{path}"}}

        true ->
          areas =
            rules
            |> Enum.filter(fn rule -> path_matches?(path, value(rule, :pattern, "")) end)
            |> Enum.flat_map(&(value(&1, :areas, []) |> List.wrap()))
            |> Enum.map(&normalize_area/1)
            |> MapSet.new()

          if MapSet.size(areas) == 0,
            do: {:halt, {:full, "changed path has no safe acceptance mapping: #{path}"}},
            else: {:cont, {:ok, MapSet.union(selected, areas)}}
      end
    end)
  end

  defp path_matches?(path, pattern) when is_binary(pattern) do
    cond do
      pattern == "" ->
        false

      String.ends_with?(pattern, "/**") ->
        String.starts_with?(path, String.trim_trailing(pattern, "**"))

      String.ends_with?(pattern, "*") ->
        String.starts_with?(path, String.trim_trailing(pattern, "*"))

      true ->
        path == pattern or String.starts_with?(path, String.trim_trailing(pattern, "/") <> "/")
    end
  end

  defp ensure_impact(markers, paths, areas) do
    if (MapSet.size(markers) > 0 or paths != []) and MapSet.size(areas) > 0,
      do: :ok,
      else: {:full, "no trustworthy commit marker or changed-path impact was provided"}
  end

  defp scenario_matches?(scenario, selected_areas),
    do: not MapSet.disjoint?(MapSet.new(areas(scenario)), selected_areas)

  defp areas(scenario),
    do:
      Enum.reject(
        scenario.tags ++ scenario.roles ++ [scenario.capability, scenario.value_stream],
        &(&1 == "")
      )

  defp phased_plan(scenarios, selected_ids, areas, markers, paths) do
    fast = Enum.filter(scenarios, &MapSet.member?(selected_ids, &1.id))
    remaining = Enum.reject(scenarios, &MapSet.member?(selected_ids, &1.id))

    %{
      mode: "incremental",
      reason: "canonical metadata plus mandatory coverage",
      areas: Enum.sort(areas),
      markers: Enum.sort(markers),
      changed_paths: paths,
      all_ids: Enum.map(scenarios, & &1.id),
      fast: phase(fast),
      remaining: phase(remaining)
    }
  end

  defp full_plan(scenarios, reason) do
    %{
      mode: "full",
      reason: reason,
      areas: [],
      markers: [],
      changed_paths: [],
      all_ids: Enum.map(scenarios, & &1.id),
      fast: phase(scenarios),
      remaining: phase([])
    }
  end

  defp phase(scenarios),
    do: %{
      scenario_ids: Enum.map(scenarios, & &1.id),
      source_files: scenarios |> Enum.map(& &1.source_file) |> Enum.uniq()
    }

  defp normalize_area(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end
end

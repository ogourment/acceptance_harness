defmodule AcceptanceHarness.FailureDiagnostics do
  @moduledoc """
  Extracts concise ExUnit failure diagnostics for ATDD evidence reports.
  """

  @failure_header_re ~r/^\s*\d+\)\s+test\s+/
  @failure_location_re ~r/^\s*(test\/[^:\s]+\.exs:\d+)\s*$/
  @failure_previews_limit 5

  @doc """
  Appends diagnostics to `report_path` and optionally writes failure artifacts.

  If `summary_path` is provided alone, it keeps the legacy behavior of writing a
  single failure summary line for first-failure tools.

  If both `summary_path` and `previews_path` are provided, `summary_path` contains
  the failure count and `previews_path` contains JSON failure previews (capped).
  """
  def append!(log_path, report_path, summary_path \\ nil, previews_path \\ nil) do
    failures = diagnose(log_path, report_path)

    markdown = markdown_for_failures(failures)

    if markdown != "" do
      report_path
      |> File.read!()
      |> insert_failures(failures)
      |> then(&File.write!(report_path, &1))
    end

    if summary_path do
      if previews_path do
        write_failure_count!(summary_path, failures)
        write_failure_previews!(previews_path, failures)
      else
        write_failure_summary!(summary_path, failures)
      end
    end

    attach_to_evidence!(failures, report_path)

    :ok
  end

  @doc """
  Formats capped failure previews for a Telegram message using Telegram's HTML
  parse mode. Preview content is escaped before interpolation.
  """
  def telegram_failure_previews(previews) when is_list(previews) do
    case Enum.take(previews, @failure_previews_limit) do
      [] ->
        ""

      previews ->
        previews
        |> Enum.map(&telegram_failure_preview_line/1)
        |> Enum.join("\n")
        |> then(&"<b>Failure preview:</b>\n#{&1}")
    end
  end

  @doc """
  Full diagnostics for a test log: failures with pending steps/scenarios and
  screenshot candidates attached.
  """
  def diagnose(log_path, report_path) do
    log_path
    |> File.read!()
    |> failures_for_log()
    |> attach_pending_steps(report_path)
    |> attach_pending_scenarios(report_path)
    |> attach_screenshots(report_path)
  end

  @doc """
  Writes each failure into `evidence.json` as the matching scenario's
  `failure` field, so the imported runtime scenario page can explain WHY a
  scenario failed (message, failing code, location, pending-step context,
  screenshot candidates) instead of showing only the steps captured before
  the crash. No-op when the evidence file is absent.
  """
  def attach_to_evidence!(failures, report_path) do
    evidence_path = report_path |> Path.dirname() |> Path.join("evidence.json")

    with true <- File.exists?(evidence_path),
         {:ok, evidence} <- evidence_path |> File.read!() |> Jason.decode() do
      scenarios =
        evidence
        |> Map.get("scenarios", [])
        |> Enum.map(fn scenario ->
          case Enum.find(failures, &failure_matches_scenario?(&1, scenario)) do
            nil -> scenario
            failure -> Map.put(scenario, "failure", failure_payload(failure))
          end
        end)

      File.write!(
        evidence_path,
        Jason.encode!(Map.put(evidence, "scenarios", scenarios), pretty: true)
      )
    end

    :ok
  end

  defp failure_matches_scenario?(failure, scenario) do
    scenario_id = Map.get(scenario, "id")
    scenario_title = Map.get(scenario, "title", "")

    pending_scenario_id =
      get_in(failure, [:pending_step, "metadata", "scenario_id"]) ||
        get_in(failure, [:pending_scenario, "id"])

    cond do
      is_binary(pending_scenario_id) -> pending_scenario_id == scenario_id
      source_matches_failure?(failure, scenario) -> true
      is_binary(failure.scenario) -> same_title?(failure.scenario, scenario_title)
      true -> false
    end
  end

  defp source_matches_failure?(%{location: location}, scenario)
       when is_binary(location) and is_map(scenario) do
    failure_path =
      location
      |> String.split(":", parts: 2)
      |> List.first()

    scenario
    |> Map.get("metadata", %{})
    |> source_path_values()
    |> Enum.any?(&same_source_path?(&1, failure_path))
  end

  defp source_matches_failure?(_failure, _scenario), do: false

  defp source_path_values(metadata) when is_map(metadata) do
    metadata
    |> Map.take(["source_file", "source_path", "file"])
    |> Map.values()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp source_path_values(_metadata), do: []

  defp same_source_path?(source_path, failure_path) do
    source_path = normalize_source_path(source_path)
    failure_path = normalize_source_path(failure_path)

    source_path == failure_path or
      String.ends_with?(failure_path, "/" <> source_path) or
      String.ends_with?(source_path, "/" <> failure_path)
  end

  defp normalize_source_path(path) do
    path
    |> to_string()
    |> String.replace("\\", "/")
    |> String.trim_leading("./")
  end

  defp same_title?(a, b), do: String.downcase(String.trim(a)) == String.downcase(String.trim(b))

  defp failure_payload(failure) do
    %{
      "title" => failure.title,
      "message" => failure.message,
      "code" => failure.code,
      "location" => failure.location,
      "details" => failure.details,
      "screenshots" => Map.get(failure, :screenshots, []),
      "pending_step" => Map.get(failure, :pending_step),
      "pending_scenario" => Map.get(failure, :pending_scenario)
    }
  end

  def markdown_for_log(log) do
    log
    |> failures_for_log()
    |> markdown_for_failures()
  end

  def failures_for_log(log) do
    extract_failures(log)
  end

  defp markdown_for_failures(failures) do
    if failures == [] do
      ""
    else
      """
      ## Test Failures

      #{Enum.map_join(failures, "\n", &failure_markdown/1)}
      """
    end
  end

  defp insert_failures(report, []), do: report

  defp insert_failures(report, failures) do
    failures = Enum.map(failures, &put_report_context(&1, report))

    insert_scenario_failures(report, failures)
    |> insert_failure_summary(failures)
  end

  defp insert_scenario_failures(report, failures) do
    Enum.reduce(failures, report, fn failure, report ->
      insert_scenario_failure(report, failure)
    end)
  end

  defp insert_scenario_failure(report, failure) do
    failure = put_report_context(failure, report)
    heading_pattern = ~r/^## [^\n]*Scenario: #{Regex.escape(failure.scenario)}\n/m

    case Regex.run(heading_pattern, report, return: :index) do
      [{start, length}] ->
        section_start = start + length
        insert_at = scenario_section_end(report, section_start)

        block = "\n#{failure_markdown(failure)}\n"

        binary_part(report, 0, insert_at) <>
          block <> binary_part(report, insert_at, byte_size(report) - insert_at)

      nil ->
        insert_orphan_failure_link(report) <> "\n\n" <> markdown_for_failures([failure])
    end
  end

  defp insert_orphan_failure_link(report) do
    if String.contains?(report, "[Test Failures](#test-failures)") do
      report
    else
      String.replace(
        report,
        "\n## Run Contexts\n",
        "\n[Test Failures](#test-failures)\n\n## Run Contexts\n",
        global: false
      )
    end
  end

  defp insert_failure_summary(report, failures) do
    if String.contains?(report, "## Failed Steps") do
      report
    else
      String.replace(
        report,
        "\n## Run Contexts\n",
        "\n#{failure_summary_markdown(failures, report)}\n## Run Contexts\n",
        global: false
      )
    end
  end

  defp failure_summary_markdown(failures, report) do
    items =
      failures
      |> Enum.map_join("\n", fn failure ->
        "- ❌ [#{failure.scenario}](#{failure_summary_anchor(failure, report)}) - #{inline_code(summary_title(failure.title))} - #{failure.message || "-"}"
      end)

    """
    ## Failed Steps

    #{outside_scenario_failure_note(failures, report)}

    #{items}
    """
  end

  defp outside_scenario_failure_note(failures, report) do
    if Enum.any?(failures, &(not scenario_section_present?(report, &1.scenario))) do
      "> ❌ Some failures happened outside documented scenarios. See [Test Failures](#test-failures) for full details."
    else
      ""
    end
  end

  defp failure_summary_anchor(failure, report) do
    cond do
      scenario_section_present?(report, failure.scenario) and
          failure_heading_present?(report, failure) ->
        "##{markdown_anchor("❌ #{failure_summary_heading(failure)}")}"

      scenario_section_present?(report, failure.scenario) ->
        "##{markdown_anchor("❌ Scenario: #{failure.scenario}")}"

      true ->
        "#test-failures"
    end
  end

  defp failure_summary_heading(failure) do
    failure
    |> failure_heading()
    |> summary_title()
  end

  defp failure_heading_present?(report, failure) do
    Regex.match?(~r/^### ❌ #{Regex.escape(failure_heading(failure))}\n/m, report)
  end

  defp scenario_section_present?(report, scenario) do
    Regex.match?(~r/^## [^\n]*Scenario: #{Regex.escape(scenario)}\n/m, report)
  end

  defp scenario_section_end(report, section_start) do
    rest = binary_part(report, section_start, byte_size(report) - section_start)

    case Regex.run(~r/^## /m, rest, return: :index) do
      [{next_heading, _length}] -> section_start + next_heading
      nil -> byte_size(report)
    end
  end

  defp markdown_anchor(heading) do
    heading
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9 -]/, "")
    |> String.replace(~r/\s+/, "-")
  end

  defp summary_title(title) do
    title
    |> to_string()
    |> String.replace(~r/\s+\([^)]+\)$/, "")
  end

  defp extract_failures(log) do
    log
    |> strip_ansi()
    |> String.split("\n")
    |> Enum.reduce({[], nil}, &collect_failure/2)
    |> then(fn {failures, current} -> finish_failure(failures, current) end)
    |> Enum.map(&parse_failure/1)
  end

  defp collect_failure(line, {failures, current}) do
    cond do
      Regex.match?(@failure_header_re, line) ->
        {finish_failure(failures, current), [line]}

      current && String.starts_with?(line, "Finished in ") ->
        {finish_failure(failures, current), nil}

      current ->
        {failures, current ++ [line]}

      true ->
        {failures, current}
    end
  end

  defp finish_failure(failures, nil), do: failures
  defp finish_failure(failures, current), do: failures ++ [current]

  defp parse_failure(lines) do
    title =
      lines
      |> List.first("")
      |> String.trim()
      |> String.replace(~r/^\s*\d+\)\s+/, "")

    location =
      Enum.find_value(lines, fn line ->
        case Regex.run(@failure_location_re, line) do
          [_match, location] -> location
          _ -> nil
        end
      end)

    message =
      lines
      |> Enum.drop_while(&(not String.match?(&1, ~r/^\s+test\//)))
      |> Enum.drop(1)
      |> Enum.find_value(fn line ->
        trimmed = String.trim(line)

        cond do
          trimmed == "" -> nil
          String.starts_with?(trimmed, "code:") -> nil
          String.starts_with?(trimmed, "stacktrace:") -> nil
          String.starts_with?(trimmed, "(") -> nil
          true -> trimmed
        end
      end)

    code =
      Enum.find_value(lines, fn line ->
        case Regex.run(~r/^\s+code:\s*(.+)$/, line) do
          [_match, code] -> code
          _ -> nil
        end
      end)

    details =
      lines
      |> Enum.drop(2)
      |> Enum.map(&String.trim_trailing/1)
      |> Enum.join("\n")
      |> String.trim()

    %{
      title: title,
      scenario: scenario_title(title),
      status_icon: "❌",
      location: location,
      message: message,
      code: code,
      details: details
    }
  end

  defp scenario_title("test " <> rest) do
    test_title =
      rest
      |> String.replace(~r/\s+\([^)]+\)$/, "")
      |> String.trim()

    scenario_title_aliases()
    |> Map.get(test_title, test_title)
    |> normalized_scenario_alias(test_title)
  end

  defp scenario_title(title) do
    title
    |> String.replace(~r/\s+\([^)]+\)$/, "")
    |> String.trim()
  end

  defp scenario_title_aliases, do: AcceptanceHarness.Config.scenario_title_aliases()

  defp normalized_scenario_alias(alias_value, _fallback) when is_binary(alias_value),
    do: alias_value

  defp normalized_scenario_alias(%{"title" => title}, _fallback) when is_binary(title),
    do: title

  defp normalized_scenario_alias(%{title: title}, _fallback) when is_binary(title),
    do: title

  defp normalized_scenario_alias(_alias_value, fallback), do: fallback

  defp failure_markdown(failure) do
    """
    ### ❌ #{failure_heading(failure)}

    #{failure_context_sentence(failure)}

    #{failure_metadata_markdown(failure)}

    Failure: **#{failure.message || "-"}**

    Location: **#{inline_code(failure.location || "-")}** - Code: **#{inline_code(failure.code || "-")}**

    ```text
    #{failure.details || "-"}
    ```

    #{failure_screenshots_markdown(failure)}
    """
  end

  defp attach_screenshots(failures, report_path) do
    screenshot_dir =
      report_path
      |> Path.dirname()
      |> Path.join("screenshots")

    screenshots =
      case File.ls(screenshot_dir) do
        {:ok, files} ->
          Enum.filter(files, fn file ->
            String.ends_with?(file, ".png") and non_empty_file?(Path.join(screenshot_dir, file))
          end)

        {:error, _reason} ->
          []
      end

    Enum.map(failures, fn failure ->
      Map.put(failure, :screenshots, matching_screenshots(failure, screenshots))
    end)
  end

  defp attach_pending_steps(failures, report_path) do
    pending_steps =
      report_path
      |> Path.dirname()
      |> Path.join("pending_steps.json")
      |> read_pending_steps()

    Enum.map(failures, fn failure ->
      Map.put(failure, :pending_step, matching_pending_step(failure, pending_steps))
    end)
  end

  defp attach_pending_scenarios(failures, report_path) do
    pending_scenarios =
      report_path
      |> Path.dirname()
      |> Path.join("pending_scenarios.json")
      |> read_pending_scenarios()

    Enum.map(failures, fn failure ->
      Map.put(failure, :pending_scenario, matching_pending_scenario(failure, pending_scenarios))
    end)
  end

  defp read_pending_steps(path) do
    with {:ok, json} <- File.read(path),
         {:ok, steps} when is_list(steps) <- Jason.decode(json) do
      steps
    else
      _ -> []
    end
  end

  defp read_pending_scenarios(path) do
    with {:ok, json} <- File.read(path),
         {:ok, scenarios} when is_list(scenarios) <- Jason.decode(json) do
      scenarios
    else
      _ -> []
    end
  end

  defp matching_pending_step(failure, pending_steps) do
    exact_scenario_steps =
      Enum.filter(pending_steps, &(get_in(&1, ["metadata", "scenario"]) == failure.scenario))

    candidate_steps =
      case exact_scenario_steps do
        [] -> Enum.filter(pending_steps, &pending_step_matches_failure?(&1, failure))
        steps -> steps
      end

    candidate_steps
    |> Enum.sort_by(&Map.get(&1, "sequence", 0))
    |> List.last()
  end

  defp pending_step_matches_failure?(pending_step, failure) do
    failure_text =
      [failure.title, failure.scenario, failure.message, failure.code]
      |> Enum.map(&diagnostic_text/1)
      |> Enum.join(" ")
      |> normalized_match_key()

    pending_text =
      [
        Map.get(pending_step, "title"),
        Map.get(pending_step, "description"),
        get_in(pending_step, ["metadata", "scenario"]),
        get_in(pending_step, ["metadata", "click_target"])
      ]
      |> Enum.map(&diagnostic_text/1)
      |> Enum.join(" ")
      |> normalized_match_key()

    pending_text != "" and
      (String.contains?(failure_text, pending_text) or
         String.contains?(pending_text, failure_text))
  end

  defp diagnostic_text(value) when is_binary(value), do: value
  defp diagnostic_text(%{"title" => title}) when is_binary(title), do: title
  defp diagnostic_text(%{title: title}) when is_binary(title), do: title
  defp diagnostic_text(nil), do: ""
  defp diagnostic_text(value), do: inspect(value)

  defp matching_pending_scenario(failure, pending_scenarios) do
    pending_scenarios
    |> Enum.filter(&(Map.get(&1, "title") == failure.scenario))
    |> Enum.sort_by(&Map.get(&1, "sequence", 0))
    |> List.last()
  end

  defp matching_screenshots(%{pending_step: %{} = _pending_step} = failure, screenshots) do
    case pending_step_screenshot(failure, screenshots) do
      nil -> test_failure_screenshot(failure, screenshots)
      screenshot -> [screenshot]
    end
  end

  defp matching_screenshots(%{pending_scenario: %{} = _pending_scenario} = failure, screenshots),
    do: test_failure_screenshot(failure, screenshots)

  defp matching_screenshots(failure, screenshots) do
    if known_scenario_title?(failure.scenario) do
      test_failure_screenshot(failure, screenshots)
    else
      []
    end
  end

  defp known_scenario_title?(title) do
    title in Map.values(scenario_title_aliases())
  end

  defp pending_step_screenshot(%{pending_step: %{"screenshot_name" => screenshot}}, screenshots)
       when is_binary(screenshot) do
    if screenshot in screenshots, do: screenshot
  end

  defp pending_step_screenshot(_failure, _screenshots), do: nil

  defp test_failure_screenshot(failure, screenshots) do
    title_key =
      failure.title
      |> String.replace(~r/^test\s+/, "")
      |> String.replace(~r/\s+\([^)]+\)$/, "")
      |> normalized_match_key()

    screenshots
    |> Enum.filter(fn screenshot ->
      screenshot
      |> Path.basename(".png")
      |> normalized_match_key()
      |> String.contains?(title_key)
    end)
    |> Enum.sort()
    |> List.last()
    |> List.wrap()
  end

  defp normalized_match_key(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "")
  end

  defp non_empty_file?(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > 0 -> true
      _ -> false
    end
  end

  defp failure_screenshots_markdown(%{screenshots: screenshots}) when screenshots != [] do
    screenshot_markdown =
      screenshots
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {screenshot, index} ->
        "![Failure screenshot #{index}](screenshots/#{screenshot})"
      end)

    """
    ::: .failure-screenshot
    #{screenshot_markdown}
    :::
    """
  end

  defp failure_screenshots_markdown(_failure), do: ""

  defp failure_metadata_markdown(%{metadata_line: metadata_line})
       when is_binary(metadata_line) and metadata_line != "" do
    metadata_line
  end

  defp failure_metadata_markdown(%{pending_step: %{"metadata" => metadata}}) do
    metadata_markdown(metadata)
  end

  defp failure_metadata_markdown(%{pending_scenario: %{"metadata" => metadata}}) do
    metadata_markdown(metadata)
  end

  defp failure_metadata_markdown(_failure), do: ""

  defp failure_context_sentence(%{pending_step: %{"description" => description}})
       when is_binary(description) and description != "" do
    "Expected: #{description}"
  end

  defp failure_context_sentence(%{pending_scenario: %{"description" => description}})
       when is_binary(description) and description != "" do
    "Expected: #{description}"
  end

  defp failure_context_sentence(%{pending_scenario: %{"title" => title}})
       when is_binary(title) and title != "" do
    "Expected: #{title}."
  end

  defp failure_context_sentence(%{step_label: _step_label, scenario: scenario})
       when is_binary(scenario) and scenario != "" do
    "Expected: #{scenario}."
  end

  defp failure_context_sentence(_failure), do: "Expected: ATDD harness completes without errors."

  defp put_report_context(failure, report) do
    heading_pattern = ~r/^## [^\n]*Scenario: #{Regex.escape(failure.scenario)}\n/m

    case Regex.run(heading_pattern, report, return: :index) do
      [{start, length}] ->
        section_start = start + length
        insert_at = scenario_section_end(report, section_start)

        failure
        |> Map.put_new(:step_label, failure_step_label(failure, report, section_start, insert_at))
        |> put_failure_metadata_line(report, section_start, insert_at)

      nil ->
        failure
    end
  end

  defp put_failure_metadata_line(
         %{pending_step: pending_step} = failure,
         _report,
         _section_start,
         _insert_at
       )
       when is_map(pending_step) do
    failure
  end

  defp put_failure_metadata_line(
         %{step_label: "After " <> _} = failure,
         report,
         section_start,
         insert_at
       ) do
    Map.put(failure, :metadata_line, last_step_metadata_line(report, section_start, insert_at))
  end

  defp put_failure_metadata_line(failure, _report, _section_start, _insert_at), do: failure

  defp failure_heading(%{pending_step: %{"metadata" => metadata, "title" => title}})
       when is_binary(title) do
    metadata
    |> Map.get("step")
    |> failed_step_heading(step_title_with_user(title, Map.get(metadata, "user")))
  end

  defp failure_heading(%{pending_scenario: %{"title" => title}}) when is_binary(title) do
    "Scenario failure: #{title}"
  end

  defp failure_heading(%{step_label: "After " <> _ = step_label, title: title}) do
    "#{step_label} - Scenario failure: #{title}"
  end

  defp failure_heading(%{step_label: step_label, title: title}) when is_binary(step_label) do
    "#{step_label} - Failed step: #{title}"
  end

  defp failure_heading(%{title: title}), do: "Outside scenario failure: #{title}"

  defp failed_step_heading(step, title) when is_binary(step) and step not in ["", "-"] do
    "#{step} - #{title}"
  end

  defp failed_step_heading(_step, title), do: "Failed step: #{title}"

  defp step_title_with_user(title, user) when is_binary(user) and user not in ["", "-"] do
    "User: #{user} - #{title}"
  end

  defp step_title_with_user(title, _user), do: title

  defp failure_step_label(
         %{pending_step: %{"metadata" => %{"step" => step}}},
         _report,
         _section_start,
         _insert_at
       )
       when is_binary(step) and step not in ["", "-"] do
    step
  end

  defp failure_step_label(_failure, report, section_start, insert_at) do
    next_step_label(report, section_start, insert_at)
  end

  defp next_step_label(report, section_start, insert_at) do
    section = binary_part(report, section_start, insert_at - section_start)

    ~r/^### (?:✅ |❌ )?(\d+)\/(\d+)\b/m
    |> Regex.scan(section)
    |> List.last()
    |> case do
      [_match, current, total] ->
        current = String.to_integer(current)
        total_int = String.to_integer(total)

        if current < total_int do
          "#{current + 1}/#{total_int}"
        else
          "After #{current}/#{total_int}"
        end

      _ ->
        nil
    end
  end

  defp last_step_metadata_line(report, section_start, insert_at) do
    section = binary_part(report, section_start, insert_at - section_start)

    ~r/^Current URL: .+$/m
    |> Regex.scan(section)
    |> List.last()
    |> case do
      [metadata_line] -> metadata_line
      _ -> nil
    end
  end

  defp metadata_markdown(metadata) when is_map(metadata) do
    [
      {"Current URL", Map.get(metadata, "current_url")},
      {"Theme", Map.get(metadata, "theme")},
      {"Device", Map.get(metadata, "device")},
      {"Viewport", Map.get(metadata, "viewport")},
      {"Language", Map.get(metadata, "language")},
      {"Click target", Map.get(metadata, "click_target")}
    ]
    |> Enum.reject(fn {_label, value} -> value in [nil, "", "-"] end)
    |> Enum.map_join(" - ", fn {label, value} -> "#{label}: **#{value}**" end)
  end

  defp first_summary(""), do: ""

  defp first_summary([]), do: ""
  defp first_summary([failure | _failures]), do: failure.message || failure.scenario || ""

  defp write_failure_count!(count_path, failures) do
    File.write!(count_path, Integer.to_string(length(failures)))
  end

  defp write_failure_previews!(previews_path, failures) do
    failures
    |> Enum.take(@failure_previews_limit)
    |> Enum.map(&failure_preview_payload/1)
    |> Jason.encode!()
    |> then(&File.write!(previews_path, &1))
  end

  defp write_failure_summary!(summary_path, failures) do
    File.write!(summary_path, first_summary(failures))
  end

  defp telegram_failure_preview_line(preview) do
    scenario =
      preview_value(preview, "scenario") || preview_value(preview, "title") || "Unknown scenario"

    message = preview_value(preview, "message") || "No failure message captured"
    location = preview_value(preview, "location")

    location_suffix =
      if location in [nil, ""] do
        ""
      else
        " (<code>#{telegram_html_escape(location)}</code>)"
      end

    "• <b>#{telegram_html_escape(scenario)}</b> — #{telegram_html_escape(message)}#{location_suffix}"
  end

  defp preview_value(preview, key) when is_map(preview) do
    atom_key =
      case key do
        "scenario" -> :scenario
        "title" -> :title
        "message" -> :message
        "location" -> :location
      end

    Map.get(preview, key) || Map.get(preview, atom_key)
  end

  defp telegram_html_escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp failure_preview_payload(failure) do
    %{
      "scenario" => failure.scenario,
      "title" => failure.scenario,
      "message" => failure.message || "",
      "location" => failure.location
    }
  end

  defp strip_ansi(text) do
    Regex.replace(~r/\e\[[0-9;]*m/, text, "")
  end

  defp inline_code(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("`", "'")

    "`#{escaped}`"
  end
end

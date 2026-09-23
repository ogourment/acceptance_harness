defmodule AcceptanceHarness.Evidence do
  @moduledoc false

  @agent __MODULE__.Agent
  @scenario_started_at_key {__MODULE__, :scenario_started_at}

  def start_scenario_runtime! do
    Process.put(@scenario_started_at_key, System.monotonic_time(:millisecond))
    :ok
  end

  def record_current_scenario_runtime(scenario) do
    case Process.get(@scenario_started_at_key) do
      started_at when is_integer(started_at) ->
        duration_ms = max(System.monotonic_time(:millisecond) - started_at, 0)
        record_scenario_runtime(scenario, duration_ms)

      _missing ->
        :ok
    end
  end

  def reset!(title, scenarios \\ [], run_context \\ %{}) do
    File.rm_rf!(report_dir())
    File.mkdir_p!(screenshot_dir())

    state = %{
      title: title,
      scenarios: Enum.map(scenarios, &normalize_scenario/1),
      run_context: default_run_context(run_context),
      job_timing: AcceptanceHarness.JobTiming.capture(),
      run_id: run_id(),
      steps: [],
      pending_steps: [],
      pending_scenarios: [],
      scenario_runtimes: [],
      successful_scenario_ids: MapSet.new(),
      ignored_failures: %{},
      started_at: System.monotonic_time(:millisecond),
      started_at_wall: DateTime.utc_now() |> DateTime.truncate(:second),
      finalized_at: nil
    }

    ensure_agent!()
    update_agent!(fn _state -> state end)
    flush_progress!(state)
  end

  def record_step(screenshot_name, title, description, metadata \\ %{}) do
    File.mkdir_p!(report_dir())

    step = %{
      screenshot_name: screenshot_name,
      title: title,
      description: description,
      metadata: metadata,
      sequence: System.unique_integer([:positive, :monotonic])
    }

    ensure_agent!()

    update_agent!(fn state ->
      state
      |> Map.update!(:steps, &(&1 ++ [step]))
      |> Map.update!(:pending_steps, &remove_pending_step(&1, step))
      |> tap(&flush_progress!/1)
    end)
  end

  def record_pending_step(screenshot_name, title, description, metadata \\ %{}) do
    File.mkdir_p!(report_dir())

    pending_step = %{
      screenshot_name: screenshot_name,
      title: title,
      description: description,
      metadata: metadata,
      sequence: System.unique_integer([:positive, :monotonic])
    }

    ensure_agent!()

    update_agent!(fn state ->
      state
      |> Map.update!(:pending_steps, &replace_pending_step(&1, pending_step))
      |> tap(&flush_progress!/1)
    end)
  end

  def record_pending_scenario(scenario, metadata \\ %{}) do
    scenario = normalize_scenario(scenario)

    pending_scenario = %{
      id: scenario.id,
      title: scenario.title,
      metadata: metadata,
      sequence: System.unique_integer([:positive, :monotonic])
    }

    ensure_agent!()

    update_agent!(fn state ->
      state
      |> Map.update!(:pending_scenarios, &replace_pending_scenario(&1, pending_scenario))
      |> tap(&flush_progress!/1)
    end)
  end

  def mark_scenario_success!(scenario) do
    scenario_id = normalize_scenario(scenario).id

    ensure_agent!()

    update_agent!(fn state ->
      state
      |> Map.update!(:successful_scenario_ids, &MapSet.put(&1, scenario_id))
      |> Map.update!(:pending_scenarios, &remove_pending_scenario(&1, scenario_id))
      |> tap(&flush_progress!/1)
    end)
  end

  def mark_scenario_ignored_failure!(scenario, message, stacktrace \\ "") do
    scenario_id = normalize_scenario(scenario).id

    ensure_agent!()

    update_agent!(fn state ->
      failure = %{message: message, stacktrace: stacktrace}

      state
      |> Map.update(
        :ignored_failures,
        %{scenario_id => failure},
        &Map.put(&1, scenario_id, failure)
      )
      |> Map.update!(:pending_scenarios, &remove_pending_scenario(&1, scenario_id))
      |> tap(&flush_progress!/1)
    end)
  end

  def record_scenario_runtime(scenario, duration_ms) when is_integer(duration_ms) do
    scenario = normalize_scenario(scenario)

    ensure_agent!()

    update_agent!(fn state ->
      runtime = %{
        scenario_id: scenario.id,
        scenario_title: scenario.title,
        duration_ms: duration_ms
      }

      state
      |> Map.update(:scenario_runtimes, [runtime], &replace_scenario_runtime(&1, runtime))
      |> tap(&flush_progress!/1)
    end)
  end

  def finalize! do
    ensure_agent!()

    update_agent!(fn state ->
      state
      |> Map.put(:finalized_at, System.monotonic_time(:millisecond))
      |> Map.put(:finalized_at_wall, DateTime.utc_now() |> DateTime.truncate(:second))
      |> tap(&flush_final!/1)
    end)
  end

  def report_path, do: Path.join(report_dir(), "e2e.md")
  def evidence_json_path, do: Path.join(report_dir(), "evidence.json")
  def report_json_path, do: evidence_json_path()

  defp ensure_agent! do
    case Process.whereis(@agent) do
      nil ->
        {:ok, _pid} =
          Agent.start_link(
            fn ->
              %{
                title: "ATDD evidence",
                scenarios: [],
                run_context: default_run_context(%{}),
                job_timing: AcceptanceHarness.JobTiming.capture(),
                run_id: run_id(),
                steps: [],
                pending_steps: [],
                pending_scenarios: [],
                scenario_runtimes: [],
                successful_scenario_ids: MapSet.new(),
                started_at: System.monotonic_time(:millisecond),
                started_at_wall: DateTime.utc_now() |> DateTime.truncate(:second),
                finalized_at: nil
              }
            end,
            name: @agent
          )

      _pid ->
        :ok
    end
  end

  # Each transition writes a consistent progress snapshot. Large suites can
  # legitimately spend more than GenServer's default five seconds rendering it.
  defp update_agent!(fun), do: Agent.update(@agent, fun, :infinity)

  defp flush_progress!(state) do
    File.mkdir_p!(report_dir())
    File.write!(report_path(), report_markdown(state))
    File.write!(Path.join(report_dir(), "pending_steps.json"), Jason.encode!(state.pending_steps))

    File.write!(
      Path.join(report_dir(), "pending_scenarios.json"),
      Jason.encode!(state.pending_scenarios)
    )
  end

  defp flush_final!(state) do
    flush_progress!(state)
    File.write!(evidence_json_path(), Jason.encode!(structured_report(state), pretty: true))
  end

  defp report_dir, do: AcceptanceHarness.Config.evidence_dir()
  defp screenshot_dir, do: AcceptanceHarness.Config.screenshot_dir()

  defp replace_pending_step(pending_steps, pending_step) do
    pending_steps
    |> Enum.reject(&(step_key(&1) == step_key(pending_step)))
    |> Kernel.++([pending_step])
  end

  defp remove_pending_step(pending_steps, step) do
    Enum.reject(pending_steps, &(step_key(&1) == step_key(step)))
  end

  defp step_key(step) do
    metadata = Map.get(step, :metadata, %{})

    {
      Map.get(metadata, "scenario_id"),
      Map.get(metadata, "step"),
      Map.get(metadata, "user"),
      Map.get(step, :title),
      Map.get(step, :screenshot_name)
    }
  end

  defp replace_pending_scenario(pending_scenarios, pending_scenario) do
    pending_scenarios
    |> Enum.reject(&(Map.get(&1, :id) == pending_scenario.id))
    |> Kernel.++([pending_scenario])
  end

  defp remove_pending_scenario(pending_scenarios, scenario_id) do
    Enum.reject(pending_scenarios, &(Map.get(&1, :id) == scenario_id))
  end

  defp report_markdown(state) do
    """
    # #{state.title}

    - Generated: **#{DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()}**
    - App version: **#{AcceptanceHarness.Config.app_version()}**
    - Commit: **#{commit_sha()}**
    - Environment: **#{System.get_env("ATDD_ENVIRONMENT", "local")}**
    - Base URL: **#{Application.get_env(:phoenix_test, :base_url)}**
    - OS: **#{inspect(:os.type())}**
    - Browser: **Chromium via PhoenixTest Playwright**

    ## Scenario Summary

    #{scenario_summary(state)}

    ## Run Contexts

    - Browser: **#{state.run_context.browser}**
    - Platform: **#{state.run_context.platform}**
    - Viewport: **#{state.run_context.viewport}**
    - Touch input: **#{touch_input(state.run_context.touch_points)}**
    - Base URL: **#{Application.get_env(:phoenix_test, :base_url)}**

    ## Run Time Breakdown

    #{run_time_breakdown(state)}

    #{scenario_sections(state)}
    """
  end

  defp structured_report(state) do
    schema_artifacts = AcceptanceHarness.SchemaHistory.capture!()

    {captured_scenarios, source_artifacts} =
      AcceptanceHarness.SourceHistory.capture!(state.scenarios)

    steps_by_scenario = Enum.group_by(state.steps, &get_in(&1, [:metadata, "scenario_id"]))

    scenarios =
      captured_scenarios
      |> Enum.with_index(1)
      |> Enum.map(fn {scenario, order} ->
        steps = scenario_steps(state.steps, scenario.id)
        runtime = Enum.find(state.scenario_runtimes, &(&1.scenario_id == scenario.id))
        runtime_ms = runtime && runtime.duration_ms
        documented_ms = total_step_duration(steps)

        %{
          id: scenario.id,
          title: scenario.title,
          status: scenario.id |> scenario_status(steps, state) |> status_label(),
          status_reason: scenario.status_reason,
          failure: Map.get(state.ignored_failures, scenario.id),
          order: order,
          duration_ms: runtime_ms,
          documented_step_ms: documented_ms,
          undocumented_ms: runtime_ms && max(runtime_ms - documented_ms, 0),
          devices: metadata_values(steps, "device"),
          themes: metadata_values(steps, "theme"),
          languages: metadata_values(steps, "language"),
          users: scenario_users(steps, scenario.metadata),
          tags: scenario_tags(steps),
          metadata: scenario.metadata,
          steps:
            Enum.map(Enum.sort_by(steps, & &1.sequence), &structured_step/1) ++
              (state.pending_steps
               |> scenario_steps(scenario.id)
               |> Enum.sort_by(& &1.sequence)
               |> Enum.map(&structured_pending_step/1))
        }
      end)

    unknown_scenarios =
      steps_by_scenario
      |> Enum.reject(fn {scenario_id, _steps} ->
        Enum.any?(captured_scenarios, &(&1.id == scenario_id))
      end)
      |> Enum.sort_by(fn {scenario_id, _steps} -> to_string(scenario_id) end)
      |> Enum.with_index(length(scenarios) + 1)
      |> Enum.map(fn {{scenario_id, steps}, order} ->
        documented_ms = total_step_duration(steps)

        %{
          id: scenario_id,
          title: steps |> List.first() |> get_in([:metadata, "scenario"]) |> empty_dash(),
          status: scenario_id |> scenario_status(steps, state) |> status_label(),
          order: order,
          duration_ms: nil,
          documented_step_ms: documented_ms,
          undocumented_ms: nil,
          devices: metadata_values(steps, "device"),
          themes: metadata_values(steps, "theme"),
          languages: metadata_values(steps, "language"),
          users: scenario_users(steps, %{}),
          tags: scenario_tags(steps),
          metadata: %{},
          steps: Enum.map(Enum.sort_by(steps, & &1.sequence), &structured_step/1)
        }
      end)

    %{
      schema_version: "acceptance_harness.evidence.v1",
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      title: state.title,
      run: %{
        id: Map.get(state, :run_id) || run_id(),
        started_at: iso8601(Map.get(state, :started_at_wall)),
        finalized_at: iso8601(Map.get(state, :finalized_at_wall))
      },
      app: %{
        name: AcceptanceHarness.Config.app_name(),
        version: AcceptanceHarness.Config.app_version(),
        commit: commit_sha(),
        pipeline_id: ci_pipeline_id(),
        environment: System.get_env("ATDD_ENVIRONMENT", "local"),
        base_url: Application.get_env(:phoenix_test, :base_url)
      },
      runner: %{
        os: inspect(:os.type()),
        browser: Map.get(state.run_context, :browser, "Chromium"),
        platform: Map.get(state.run_context, :platform),
        viewport: Map.get(state.run_context, :viewport),
        touch_points: Map.get(state.run_context, :touch_points)
      },
      timing:
        Map.merge(Map.get(state, :job_timing, %{}), %{
          pipeline_age_ms: pipeline_age_ms(),
          wall_time_ms: wall_duration(state),
          documented_step_ms: total_step_duration(state.steps),
          undocumented_ms: uncaptured_duration(state),
          finalized: not is_nil(state.finalized_at)
        }),
      scenarios: scenarios ++ unknown_scenarios,
      pending_steps: Enum.map(state.pending_steps, &structured_step/1),
      pending_scenarios: state.pending_scenarios,
      artifacts:
        [
          %{type: "markdown", path: "e2e.md"},
          %{type: "legacy_markdown", path: "journeys.md"}
        ] ++ schema_artifacts ++ source_artifacts
    }
  end

  defp structured_step(step) do
    # Page text/HTML are captured for FTS and agent selector work; they are
    # promoted out of metadata so they never render as metadata pills.
    {page_text, metadata} = Map.pop(step.metadata, "page_text")
    {page_html, metadata} = Map.pop(metadata, "page_html")
    {surface, metadata} = Map.pop(metadata, "surface", %{"kind" => "browser"})
    {artifacts, metadata} = Map.pop(metadata, "artifacts", [])

    %{
      id: step_id(step),
      scenario_id: get_in(step, [:metadata, "scenario_id"]),
      title: step.title,
      description: step.description,
      screenshot: %{
        name: step.screenshot_name,
        path: Path.join("screenshots", step.screenshot_name)
      },
      sequence: step.sequence,
      tags: step_tags(step),
      page: %{text: page_text, html: page_html},
      surface: surface,
      artifacts: artifacts,
      metadata: Map.delete(metadata, "tags"),
      status: "success"
    }
  end

  defp structured_pending_step(step) do
    step
    |> structured_step()
    |> Map.put(:screenshot, nil)
    |> Map.put(:status, "not_reached")
  end

  defp step_tags(step) do
    step.metadata
    |> Map.get("tags")
    |> normalize_tags()
  end

  defp normalize_tags(nil), do: []

  defp normalize_tags(tags) when is_binary(tags) do
    tags
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&blank?/1)
  end

  defp normalize_tags(tags) when is_list(tags) do
    tags
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&blank?/1)
  end

  defp normalize_tags(_tags), do: []

  defp scenario_tags(steps) do
    steps
    |> Enum.flat_map(&step_tags/1)
    |> Enum.uniq()
  end

  defp scenario_users(steps, metadata) do
    scenario_roles =
      [
        Map.get(metadata, "roles"),
        Map.get(metadata, "role"),
        Map.get(metadata, "users"),
        Map.get(metadata, "user")
      ]
      |> Enum.flat_map(&normalize_tags/1)

    steps
    |> metadata_values("user")
    |> Kernel.++(scenario_roles)
    |> Enum.uniq()
  end

  defp metadata_values(steps, key) do
    steps
    |> Enum.map(&get_in(&1, [:metadata, key]))
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  defp step_id(step) do
    [
      get_in(step, [:metadata, "scenario_id"]),
      Map.get(step.metadata, "step"),
      Map.get(step.metadata, "user"),
      step.screenshot_name,
      step.sequence
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.map(&slug/1)
    |> Enum.join("-")
  end

  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(_value), do: nil

  defp run_time_breakdown(state) do
    """
    - Full pipeline age at report generation: **#{duration_label(pipeline_age_ms())}**
    - ATDD job queue wait: **#{duration_label(get_in(state, [:job_timing, :job_wait_ms]))}**
    - ATDD report wall time {{help:Elapsed time from starting the evidence collector until the report is written.}}: **#{duration_label(wall_duration(state))}**
    - Documented step time: **#{duration_label(total_step_duration(state.steps))}** across **#{length(state.steps)}** evidence steps
    - Undocumented ATDD work: **#{duration_label(uncaptured_duration(state))}**

    ### Scenario Runtime Detail

    #{scenario_runtime_table(state)}
    """
  end

  defp scenario_sections(state) do
    known_ids = MapSet.new(Enum.map(state.scenarios, & &1.id))
    grouped_steps = Enum.group_by(state.steps, &get_in(&1, [:metadata, "scenario_id"]))

    known_sections =
      state.scenarios
      |> Enum.map(fn scenario ->
        scenario_section(scenario, Map.get(grouped_steps, scenario.id, []), state)
      end)

    unknown_sections =
      grouped_steps
      |> Enum.reject(fn {scenario_id, _steps} -> MapSet.member?(known_ids, scenario_id) end)
      |> Enum.sort_by(fn {scenario_id, _steps} -> to_string(scenario_id) end)
      |> Enum.map(fn {scenario_id, steps} ->
        title =
          steps
          |> List.first()
          |> get_in([:metadata, "scenario"])
          |> empty_dash()

        scenario_section(%{id: scenario_id, title: title}, steps, state)
      end)

    (known_sections ++ unknown_sections)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp scenario_section(scenario, [], state) do
    status = scenario_status(scenario.id, [], state)

    disposition =
      scenario_disposition(
        status,
        Map.get(scenario, :status_reason),
        Map.get(state.ignored_failures, scenario.id)
      )

    """
    ## #{scenario_status_icon(status)} Scenario: #{scenario.title}

    #{disposition || "No evidence steps were captured for this scenario."}

    #{state.pending_steps |> scenario_steps(scenario.id) |> Enum.sort_by(& &1.sequence) |> Enum.map(&pending_step_markdown/1) |> Enum.join("\n")}
    """
  end

  defp scenario_section(scenario, steps, state) do
    status = scenario_status(scenario.id, steps, state)

    disposition =
      scenario_disposition(
        status,
        Map.get(scenario, :status_reason),
        Map.get(state.ignored_failures, scenario.id)
      )

    """
    ## #{scenario_status_icon(status)} Scenario: #{scenario.title}

    #{disposition}

    #{multi_user_timeline(steps)}

    #{steps |> Enum.sort_by(& &1.sequence) |> Enum.map(&step_markdown/1) |> Enum.join("\n")}

    #{state.pending_steps |> scenario_steps(scenario.id) |> Enum.sort_by(& &1.sequence) |> Enum.map(&pending_step_markdown/1) |> Enum.join("\n")}
    """
  end

  defp pending_step_markdown(step) do
    """
    ### ❌ #{Map.get(step.metadata, "step", "-")} - #{step.title} (not reached)

    #{step.description}

    #{metadata_markdown(step.metadata)}
    """
  end

  defp step_markdown(step) do
    evidence = step_evidence_markdown(step)

    """
    ### #{step_heading(step)}

    #{step.description}

    #{metadata_markdown(step.metadata)}

    #{evidence}
    """
  end

  defp step_evidence_markdown(step) do
    case Map.get(step.metadata, "surface") do
      %{"kind" => "terminal", "text" => text} when is_binary(text) ->
        """
        ```terminal
        #{text}
        ```

        #{artifact_markdown(Map.get(step.metadata, "artifacts", []))}
        """

      %{"kind" => "message_timeline", "frames" => frames} = surface when is_list(frames) ->
        channel = Map.get(surface, "channel", "unspecified")

        frames =
          Enum.map_join(frames, "\n\n", fn frame ->
            at_ms = Map.get(frame, "at_ms", 0)
            operation = Map.get(frame, "operation", "observe")
            state = Map.get(frame, "state", "unknown")
            role = Map.get(frame, "role")
            text = Map.get(frame, "text", "")
            role_suffix = if role in ["user", "assistant", "system"], do: " · #{role}", else: ""

            "**+#{format_timeline_ms(at_ms)} · #{operation} · #{state}#{role_suffix}**\n\n```text\n#{text}\n```"
          end)

        "**Message timeline — #{channel}**\n\n#{frames}"

      _surface ->
        "![#{step.title}](screenshots/#{step.screenshot_name})"
    end
  end

  defp format_timeline_ms(value) when is_integer(value) and value < 1_000, do: "#{value} ms"

  defp format_timeline_ms(value) when is_integer(value) do
    seconds = value / 1_000
    :erlang.float_to_binary(seconds, decimals: 1) |> String.trim_trailing(".0") |> Kernel.<>("s")
  end

  defp format_timeline_ms(_value), do: "?"

  defp artifact_markdown(artifacts) when is_list(artifacts) do
    artifacts
    |> Enum.filter(&(is_map(&1) and is_binary(Map.get(&1, "path"))))
    |> Enum.map_join("\n", fn artifact ->
      label = Map.get(artifact, "label") || Map.get(artifact, "type") || "Artifact"
      "- [#{artifact_label(label)}](#{artifact_href(Map.fetch!(artifact, "path"))})"
    end)
  end

  defp artifact_markdown(_artifacts), do: ""

  defp artifact_label(label) do
    label
    |> to_string()
    |> String.replace(~r/[\[\]\r\n]/u, " ")
    |> String.trim()
  end

  defp artifact_href(path) do
    URI.encode(path, fn character ->
      URI.char_unreserved?(character) or character == ?/
    end)
  end

  defp scenario_summary(%{scenarios: [], steps: []}), do: "No scenarios recorded."

  defp scenario_summary(state) do
    rows =
      state.scenarios
      |> Enum.with_index(1)
      |> Enum.map(fn {scenario, index} ->
        steps = scenario_steps(state.steps, scenario.id)
        status = scenario_status(scenario.id, steps, state)

        "| #{index} | #{scenario_status_icon(status)} | [#{scenario.title}](##{anchor("#{scenario_status_icon(status)} Scenario: #{scenario.title}")}) | #{summary_values(steps, "device")} | #{summary_values(steps, "theme")} | #{summary_values(steps, "language")} | #{duration_label(total_step_duration(steps))} |"
      end)
      |> Enum.join("\n")

    """
    | # | Status | Scenario | Devices | Themes | Languages | Duration |
    | --- | --- | --- | --- | --- | --- | --- |
    #{rows}
    """
  end

  defp summary_values(steps, key) do
    steps
    |> Enum.map(&get_in(&1, [:metadata, key]))
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> case do
      [] -> "-"
      values -> Enum.join(values, ", ")
    end
  end

  defp scenario_runtime_table(%{scenario_runtimes: []}) do
    "No scenario runtime samples recorded."
  end

  defp scenario_runtime_table(state) do
    rows =
      state.scenario_runtimes
      |> Enum.sort_by(fn runtime ->
        Enum.find_index(state.scenarios, &(&1.id == runtime.scenario_id)) || 999
      end)
      |> Enum.map(fn runtime ->
        steps = scenario_steps(state.steps, runtime.scenario_id)
        documented_ms = total_step_duration(steps)
        undocumented_ms = max(runtime.duration_ms - documented_ms, 0)

        "| #{escape_table_cell(runtime.scenario_title)} | #{duration_label(runtime.duration_ms)} | #{duration_label(documented_ms)} | #{duration_label(undocumented_ms)} |"
      end)
      |> Enum.join("\n")

    """
    | Scenario | Elapsed | Documented steps | Undocumented |
    | --- | ---: | ---: | ---: |
    #{rows}
    """
  end

  defp replace_scenario_runtime(runtimes, runtime) do
    runtimes
    |> Enum.reject(&(&1.scenario_id == runtime.scenario_id))
    |> Kernel.++([runtime])
  end

  defp scenario_status(scenario_id, steps, state) do
    cond do
      MapSet.member?(state.successful_scenario_ids, scenario_id) ->
        :success

      declared_status(state, scenario_id) in [:ignored, :skipped] ->
        declared_status(state, scenario_id)

      state.finalized_at ->
        :failure

      steps == [] ->
        :not_run

      true ->
        :running
    end
  end

  defp scenario_steps(steps, scenario_id) do
    Enum.filter(steps, &(get_in(&1, [:metadata, "scenario_id"]) == scenario_id))
  end

  defp scenario_status_icon(:success), do: "✅"
  defp scenario_status_icon(:failure), do: "❌"
  defp scenario_status_icon(:running), do: "⏳"
  defp scenario_status_icon(:ignored), do: "🟠"
  defp scenario_status_icon(:skipped), do: "⬛"
  defp scenario_status_icon(:not_run), do: "⚪"

  defp status_label(:success), do: "success"
  defp status_label(:failure), do: "failure"
  defp status_label(:running), do: "running"
  defp status_label(:ignored), do: "ignored"
  defp status_label(:skipped), do: "skipped"
  defp status_label(:not_run), do: "not_run"

  defp declared_status(state, scenario_id) do
    state.scenarios
    |> Enum.find(&(&1.id == scenario_id))
    |> case do
      %{declared_status: status} -> status
      _scenario -> nil
    end
  end

  defp scenario_disposition(:ignored, reason, %{message: message}) do
    "**Ignored:** #{reason}\n\n**Observed failure:** #{message}"
  end

  defp scenario_disposition(:ignored, reason, _failure), do: "**Ignored:** #{reason}"
  defp scenario_disposition(:skipped, reason, _failure), do: "**Skipped:** #{reason}"
  defp scenario_disposition(_status, _reason, _failure), do: nil

  defp anchor(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^[:alnum:] -]/u, "")
    |> String.replace(~r/\s+/, "-")
  end

  defp metadata_markdown(metadata) when map_size(metadata) == 0, do: ""

  defp metadata_markdown(metadata) do
    [
      {"Current URL", Map.get(metadata, "current_url")},
      {"Theme", Map.get(metadata, "theme")},
      {"Device", Map.get(metadata, "device")},
      {"Viewport", Map.get(metadata, "viewport")},
      {"Language", Map.get(metadata, "language")},
      {"Click target", Map.get(metadata, "click_target")}
    ]
    |> Enum.reject(fn {_label, value} -> blank?(value) or value == "-" end)
    |> Enum.map_join(" - ", fn {label, value} -> "#{label}: **#{value}**" end)
  end

  defp multi_user_timeline(steps) do
    steps = Enum.sort_by(steps, & &1.sequence)

    users =
      steps |> Enum.map(&get_in(&1, [:metadata, "user"])) |> Enum.reject(&blank?/1) |> Enum.uniq()

    if length(users) < 2 do
      ""
    else
      rows =
        steps
        |> Enum.group_by(&Map.get(&1.metadata, "step", "-"))
        |> Enum.sort_by(fn {step, grouped_steps} ->
          {step_order(step), grouped_steps |> Enum.map(& &1.sequence) |> Enum.min()}
        end)
        |> Enum.map(fn {step, grouped_steps} ->
          grouped_by_user = Enum.group_by(grouped_steps, &get_in(&1, [:metadata, "user"]))

          cells =
            Enum.map(users, fn user ->
              grouped_by_user
              |> Map.get(user, [])
              |> Enum.map_join("<br>", &screenshot_link/1)
              |> empty_dash()
            end)

          "| #{Enum.join([step | cells], " | ")} |"
        end)

      """
      ### Multi-user view

      | Step | #{Enum.join(users, " | ")} |
      | #{Enum.map_join([nil | users], " | ", fn _ -> "---" end)} |
      | View | #{Enum.map_join(users, " | ", &user_view_label(steps, &1))} |
      #{Enum.join(rows, "\n")}
      """
    end
  end

  defp user_view_label(steps, user) do
    metadata =
      Enum.find_value(steps, %{}, fn step ->
        if get_in(step, [:metadata, "user"]) == user do
          step.metadata
        end
      end)

    [
      Map.get(metadata, "device"),
      Map.get(metadata, "viewport"),
      Map.get(metadata, "theme"),
      Map.get(metadata, "language")
    ]
    |> Enum.reject(fn value -> blank?(value) or value == "-" end)
    |> Enum.join(" · ")
    |> empty_dash()
    |> escape_table_cell()
  end

  defp blank?(value), do: value in [nil, ""]

  defp screenshot_link(step) do
    "![#{escape_table_cell(step.title)}](screenshots/#{step.screenshot_name})"
  end

  defp escape_table_cell(value) do
    value
    |> to_string()
    |> String.replace("|", "\\|")
  end

  defp step_order(value) do
    value
    |> to_string()
    |> String.split("/", parts: 2)
    |> List.first()
    |> Integer.parse()
    |> case do
      {integer, _rest} -> integer
      :error -> 999
    end
  end

  defp step_heading(step) do
    duration = duration_label(get_in(step, [:metadata, "duration_ms"]))
    step_index = Map.get(step.metadata, "step", "-")
    title = step_title_with_user(step.title, Map.get(step.metadata, "user"))

    if blank?(step_index) or step_index == "-" do
      "✅ #{title} (#{duration})"
    else
      "✅ #{step_index} - #{title} (#{duration})"
    end
  end

  defp step_title_with_user(title, user) do
    if blank?(user) or user == "-" do
      title
    else
      "User: #{user} - #{title}"
    end
  end

  defp default_run_context(run_context) do
    %{
      browser: Map.get(run_context, "browser", "Chromium"),
      platform: Map.get(run_context, "platform", "unknown"),
      viewport: Map.get(run_context, "viewport", "unknown"),
      touch_points: Map.get(run_context, "touch_points", "unknown")
    }
  end

  defp normalize_scenario(%{id: id, title: title} = scenario) do
    metadata =
      scenario
      |> Map.get(:metadata)
      |> case do
        metadata when is_map(metadata) -> metadata
        _metadata -> %{}
      end
      |> Map.merge(facet_metadata(scenario))
      |> Map.merge(identity_metadata(scenario))
      |> Map.merge(source_metadata(scenario))
      |> maybe_put_status_reason(scenario)

    declared_status = Map.get(scenario, :status)

    if declared_status in [:ignored, :skipped] and blank?(Map.get(scenario, :reason)) do
      raise ArgumentError, "#{declared_status} scenario #{inspect(id)} requires a nonblank reason"
    end

    %{
      id: to_string(id),
      title: to_string(title),
      metadata: metadata,
      declared_status: declared_status,
      status_reason: Map.get(scenario, :reason)
    }
  end

  defp maybe_put_status_reason(metadata, %{reason: reason}) when is_binary(reason),
    do: Map.put(metadata, "status_reason", reason)

  defp maybe_put_status_reason(metadata, _scenario), do: metadata

  defp identity_metadata(scenario) do
    legacy_ids =
      scenario
      |> Map.get(:legacy_ids, [])
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if legacy_ids == [], do: %{}, else: %{"legacy_ids" => legacy_ids}
  end

  defp source_metadata(scenario) do
    scenario
    |> Map.take([:source_path, :source_file, :source_test, :source_checksum, :source_sha256])
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Map.new()
    |> maybe_put_source_checksum()
  end

  defp facet_metadata(scenario) do
    scenario
    |> Map.take([:role, :roles, :user, :users])
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Map.new()
  end

  defp maybe_put_source_checksum(%{"source_checksum" => checksum} = metadata)
       when is_binary(checksum) and checksum != "" do
    metadata
  end

  defp maybe_put_source_checksum(%{"source_sha256" => checksum} = metadata)
       when is_binary(checksum) and checksum != "" do
    Map.put(metadata, "source_checksum", checksum)
  end

  defp maybe_put_source_checksum(metadata) do
    case AcceptanceHarness.ScenarioSource.read(metadata) do
      {:ok, contents, _extension} ->
        checksum = :sha256 |> :crypto.hash(contents) |> Base.encode16(case: :lower)
        Map.put(metadata, "source_checksum", checksum)

      :error ->
        metadata
    end
  end

  defp total_step_duration(steps) do
    steps
    |> Enum.map(&get_in(&1, [:metadata, "duration_ms"]))
    |> Enum.filter(&is_integer/1)
    |> Enum.sum()
  end

  defp duration_label(value) when is_integer(value) do
    cond do
      value < 1_000 ->
        "#{value} ms"

      value < 60_000 ->
        seconds = round(value / 1_000)
        "#{seconds}s"

      true ->
        minutes = div(value, 60_000)
        seconds = rem(value, 60_000) |> div(1_000)
        "#{minutes}m #{seconds}s"
    end
  end

  defp duration_label(_value), do: "-"

  defp wall_duration(%{finalized_at: nil, started_at: started_at}) do
    System.monotonic_time(:millisecond) - started_at
  end

  defp wall_duration(%{finalized_at: finalized_at, started_at: started_at}) do
    finalized_at - started_at
  end

  defp uncaptured_duration(state) do
    max(wall_duration(state) - total_step_duration(state.steps), 0)
  end

  defp pipeline_age_ms do
    duration_until_now_ms(System.get_env("CI_PIPELINE_CREATED_AT"))
  end

  defp ci_pipeline_id do
    case System.get_env("CI_PIPELINE_ID") do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp duration_until_now_ms(nil), do: nil

  defp duration_until_now_ms(value) do
    with {:ok, started_at} <- ci_datetime(value) do
      DateTime.utc_now()
      |> DateTime.diff(started_at, :millisecond)
      |> max(0)
    else
      _ -> nil
    end
  end

  defp ci_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      error -> error
    end
  end

  defp ci_datetime(_value), do: :error

  defp touch_input("0"), do: "No touch input reported (maxTouchPoints 0)"
  defp touch_input(0), do: "No touch input reported (maxTouchPoints 0)"
  defp touch_input("unknown"), do: "Unknown"
  defp touch_input(nil), do: "Unknown"

  defp touch_input(value) do
    "Touch input reported (maxTouchPoints #{value})"
  end

  defp run_id do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    "run-#{slug(timestamp)}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp slug(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp empty_dash(nil), do: "-"
  defp empty_dash(""), do: "-"
  defp empty_dash(value), do: value

  defp git_sha do
    if command_available?("git") do
      case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
        {sha, 0} -> String.trim(sha)
        _ -> "unknown"
      end
    else
      "unknown"
    end
  end

  defp commit_sha do
    AcceptanceHarness.Config.commit_sha_env()
    |> Enum.find_value(&System.get_env/1)
    |> Kernel.||(git_sha())
  end

  defp command_available?(command) do
    System.find_executable(command) != nil
  end
end

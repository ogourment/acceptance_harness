defmodule AcceptanceHarnessWeb.ScenarioLive do
  @moduledoc false
  use Phoenix.LiveView

  alias AcceptanceHarness.AdminStore
  alias AcceptanceHarness.Timing

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       run_id: nil,
       run: nil,
       scenario_id: nil,
       scenario: nil,
       scenario_change_status: nil,
       scenario_change_details: nil,
       scenario_source_diff: nil,
       schema_history: empty_schema_history(),
       scenario_navigation: nil,
       steps: [],
       error: nil,
       root_path: nil
     )}
  end

  def handle_params(%{"run_id" => run_id, "scenario_id" => scenario_id}, uri, socket) do
    root_path = uri |> URI.parse() |> Map.fetch!(:path) |> String.replace(~r{/runs/.*$}, "")

    socket =
      socket
      |> assign(
        run_id: run_id,
        scenario_id: scenario_id,
        root_path: root_path
      )
      |> load_scenario(run_id, scenario_id)

    {:noreply, socket}
  end

  def render(assigns) do
    assigns =
      assigns
      |> Map.put_new(:scenario_change_status, nil)
      |> Map.put_new(:scenario_change_details, nil)
      |> Map.put_new(:scenario_source_diff, nil)
      |> Map.put_new(:schema_history, empty_schema_history())
      |> Map.put_new(:scenario_navigation, nil)
      |> Map.put_new(:run, %{})

    ~H"""
    <AcceptanceHarnessWeb.AdminAssets.styles />
    <AcceptanceHarnessWeb.AdminAssets.review_activity />
    <AcceptanceHarnessWeb.AdminAssets.screenshot_preview />
    <main class="acceptance-admin acceptance-scenario" data-review-run={@run_id} data-review-scenario={@scenario_id} data-review-endpoint={"#{@root_path}/review-activity"}>
      <nav class="acceptance-breadcrumb">
        <div class="acceptance-breadcrumb-path">
          <a href={run_path(@root_path, @run_id)}>Run</a>
          <span>/</span>
          <span>Scenario</span>
        </div>
        <div :if={@scenario_navigation} class="acceptance-scenario-navigation" aria-label="Scenario navigation">
          <a
            :if={@scenario_navigation.previous}
            class="acceptance-scenario-nav-link"
            href={scenario_path(@root_path, @run_id, @scenario_navigation.previous)}
            rel="prev"
          >
            Prev
          </a>
          <span :if={!@scenario_navigation.previous} class="acceptance-scenario-nav-link is-disabled">Prev</span>
          <span class="acceptance-scenario-cursor">
            (<%= @scenario_navigation.position %>/<%= @scenario_navigation.total %>)
          </span>
          <a
            :if={@scenario_navigation.next}
            class="acceptance-scenario-nav-link"
            href={scenario_path(@root_path, @run_id, @scenario_navigation.next)}
            rel="next"
          >
            Next
          </a>
          <span :if={!@scenario_navigation.next} class="acceptance-scenario-nav-link is-disabled">Next</span>
        </div>
      </nav>

      <p :if={@error} class="acceptance-error"><%= @error %></p>

      <section :if={@scenario} data-review-target="scenario" id="acceptance-run-timing" class="acceptance-panel acceptance-timing-panel">
        <p class="acceptance-kicker">Run timing</p>
        <dl class="acceptance-timing-grid">
          <div :for={metric <- Timing.run_metrics(@run)}>
            <dt><%= metric.label %></dt>
            <dd><%= metric.value %></dd>
            <small><%= metric.help %></small>
          </div>
        </dl>
      </section>

      <section :if={@scenario} id="acceptance-scenario-output">
        <header class={"acceptance-hero acceptance-scenario-hero #{status_class(@scenario, @scenario_change_status)}"}>
          <div>
            <p class="acceptance-kicker">
              <span class="acceptance-status-pill"><%= status_label(@scenario["status"] || @scenario[:status]) %></span>
              <span><%= @scenario["scenario_id"] || @scenario[:scenario_id] %></span>
            </p>
            <h1>
              <%= @scenario["title"] || @scenario[:title] %>
            </h1>
            <p :if={failure_message(@scenario)} class="acceptance-scenario-failure-preview">
              <strong>Failure:</strong> <%= failure_message(@scenario) %>
            </p>
            <div class="acceptance-scenario-facets" aria-label="Scenario facets">
              <span :for={device <- scenario_values(@scenario, "devices")} class="acceptance-facet-pill">
                Device: <%= device %>
              </span>
              <span :for={language <- scenario_values(@scenario, "languages")} class="acceptance-facet-pill">
                Language: <%= language %>
              </span>
              <span :for={user <- scenario_values(@scenario, "users")} class="acceptance-facet-pill">
                Role: <%= user %>
              </span>
              <span :for={tag <- scenario_values(@scenario, "tags")} class="acceptance-facet-pill">
                Tag: <%= tag %>
              </span>
            </div>
            <p class="acceptance-lede">Inspect the captured evidence, source changes, and failures for this scenario.</p>
            <dl class="acceptance-scenario-timing" aria-label="Scenario timing">
              <div :for={metric <- Timing.scenario_metrics(@scenario)}>
                <dt><%= metric.label %></dt>
                <dd><%= metric.value %></dd>
              </div>
            </dl>
          </div>
          <div class="acceptance-scenario-actions">
            <dl class="acceptance-summary-strip">
              <div>
                <dt>Steps</dt>
                <dd><%= length(@steps) %></dd>
              </div>
            </dl>
          </div>
          <details
            :if={scenario_change_status(@scenario_change_status)}
            id="scenario-change-details"
            class={"acceptance-change-details acceptance-scenario-change-details #{scenario_change_badge_class(@scenario_change_status)}"}
          >
            <summary>
              <span
                class={"acceptance-change-badge #{scenario_change_badge_class(@scenario_change_status)}"}
                aria-hidden="true"
              >
                <.scenario_change_icon status={scenario_change_status(@scenario_change_status)} />
              </span>
              <span>
                <strong><%= scenario_change_aria_label(@scenario_change_status) %></strong>
                <span>— What changed?</span>
              </span>
            </summary>
            <div class="acceptance-change-details-body">
              <p>
                <strong><%= scenario_change_reason(@scenario_change_status) %></strong>
                <span :if={previous_run_id(@scenario_change_details)}>
                  · Compared with
                  <a href={run_path(@root_path, previous_run_id(@scenario_change_details))}>
                    <%= previous_run_id(@scenario_change_details) %>
                  </a>
                </span>
              </p>
              <p :if={title_changed?(@scenario, @scenario_change_details)}>
                Title: <del><%= previous_title(@scenario_change_details) %></del>
                <span aria-hidden="true">→</span>
                <ins><%= @scenario["title"] || @scenario[:title] %></ins>
              </p>
              <div :if={@scenario_source_diff} class="acceptance-source-diff">
                <p class="acceptance-muted">
                  <code><%= @scenario_source_diff.source_file %></code>
                  · <%= pluralized_count(@scenario_source_diff.additions, "addition", "additions") %>
                  · <%= pluralized_count(@scenario_source_diff.deletions, "deletion", "deletions") %>
                </p>
                <div class="acceptance-source-diff-lines" role="table" aria-label="Scenario source changes">
                  <div
                    :for={row <- @scenario_source_diff.rows}
                    class={"acceptance-source-diff-line is-#{row.kind}"}
                    role="row"
                  >
                    <span class="acceptance-source-diff-number" role="cell"><%= row.old_line || "" %></span>
                    <span class="acceptance-source-diff-number" role="cell"><%= row.new_line || "" %></span>
                    <span class="acceptance-source-diff-marker" aria-hidden="true"><%= source_diff_marker(row.kind) %></span>
                    <code role="cell"><%= row.text %></code>
                  </div>
                </div>
              </div>
              <p
                :if={@scenario_change_status == "delta" && !@scenario_source_diff}
                class="acceptance-muted"
              >
                A source snapshot is not available for both runs, so the changed source lines
                cannot be reconstructed for this comparison.
              </p>
              <ul :if={changed_steps(@steps) != []} class="acceptance-scenario-change-step-list">
                <li :for={step <- changed_steps(@steps)}>
                  <a href={"#step-#{step.id}"}>
                    <%= step_change_label(step) %> step: <%= step.title %>
                  </a>
                </li>
              </ul>
              <p :if={changed_steps(@steps) == [] && @scenario_change_status == "delta"}>
                <strong>No recorded step changed.</strong>
                Review scenario setup, assertions, or code outside the captured steps.
              </p>
              <p class="acceptance-muted"><%= step_change_count_summary(@steps) %></p>
            </div>
          </details>
        </header>

        <aside
          :if={@schema_history.changes != []}
          class="acceptance-panel acceptance-scenario-schema-context"
          aria-label="Release-level schema changes"
        >
          <p class="acceptance-kicker">Release-level context</p>
          <h2>Changed domain schemas</h2>
          <p>
            The run also changed
            <%= schema_domain_sentence(@schema_history.changes) %>.
            This is not automatically attributed to this scenario.
          </p>
          <ul>
            <li :for={change <- @schema_history.changes}>
              <a href={schema_domain_url(@root_path, @run_id, change.domain_id)}>
                <%= change.label %> — <%= schema_change_label(change.status) %>
              </a>
            </li>
          </ul>
        </aside>

        <section
          :if={scenario_failure(@scenario)}
          id="scenario-failure"
          class="acceptance-panel acceptance-failure"
        >
          <div class="acceptance-panel-heading">
            <h2>Why it failed</h2>
          </div>
          <p class="acceptance-failure-message">
            <strong><%= scenario_failure(@scenario)["message"] || "Test failed" %></strong>
          </p>
          <p class="acceptance-muted">
            <code><%= scenario_failure(@scenario)["location"] || "-" %></code>
            <span :if={scenario_failure(@scenario)["code"]}>
              · <code><%= scenario_failure(@scenario)["code"] %></code>
            </span>
          </p>
          <div :if={failure_pending_step(@scenario)} class="acceptance-failure-context">
            <p class="acceptance-card-meta">Context at failure</p>
            <p>
              <strong><%= failure_pending_step(@scenario)["title"] %></strong>
              <span :if={failure_pending_step(@scenario)["description"] not in [nil, ""]}>
                — <%= failure_pending_step(@scenario)["description"] %>
              </span>
            </p>
          </div>
          <div :if={failure_screenshots(@scenario) != []} class="acceptance-failure-screenshots">
            <a
              :for={name <- failure_screenshots(@scenario)}
              class="acceptance-screenshot-link"
              href={screenshot_path(@root_path, @run_id, name)}
            >
              <img src={screenshot_path(@root_path, @run_id, name)} alt={name} />
            </a>
          </div>
          <details :if={scenario_failure(@scenario)["details"] not in [nil, ""]}>
            <summary>Full diagnostic</summary>
            <pre class="acceptance-failure-details"><%= scenario_failure(@scenario)["details"] %></pre>
          </details>
        </section>

        <section class="acceptance-steps">
            <article :if={unmatched_failure?(@scenario, @steps)} class="acceptance-step acceptance-step-failure">
              <div class="acceptance-step-copy">
                <div class="acceptance-step-heading">
                  <p class="acceptance-step-index">Failure before a recorded step</p>
                </div>
                <h2><%= failure_title(@scenario) %></h2>
                <p class="acceptance-failure-message"><%= failure_message(@scenario) %></p>
                <p class="acceptance-muted"><code><%= failure_location(@scenario) %></code></p>
              </div>
              <a
                :if={failure_screenshot(@scenario)}
                class="acceptance-screenshot-link"
                href={screenshot_path(@root_path, @run_id, failure_screenshot(@scenario))}
              >
                <img src={screenshot_path(@root_path, @run_id, failure_screenshot(@scenario))} alt="Failure screenshot" />
              </a>
            </article>
            <article
              :for={{step, index} <- Enum.with_index(@steps, 1)}
              id={"step-#{step.id}"}
              class={"acceptance-step #{step_card_class(@scenario, step)}"}
              data-acceptance-step-id={step.id}
              data-acceptance-step-sequence={step_position(step, index)}
            >
              <div class="acceptance-step-copy">
                <div class="acceptance-step-heading">
                  <p class="acceptance-step-index">
                    Step <%= step_position(step, index) %>
                    <span class="acceptance-step-duration">· <%= Timing.step_label(step, @scenario["status"] || @scenario[:status]) %></span>
                    <a
                      class="acceptance-step-export"
                      href={step_export_path(@root_path, step.id)}
                      title="Step-level Markdown export for agents"
                    >.md</a>
                  </p>
                </div>
                <h2><%= step.title %></h2>
                <p><%= step.description %></p>
                <p :if={step_failed?(@scenario, step)} class="acceptance-step-failure-message">
                  <strong>Failure:</strong> <%= failure_message(@scenario) %>
                </p>
                <p :if={metadata_value(step.metadata, "current_url") != ""} class="acceptance-current-url">
                  <a href={metadata_value(step.metadata, "current_url")} target="_blank" rel="noreferrer">
                    <%= metadata_value(step.metadata, "current_url") %>
                  </a>
                </p>
                <dl class="acceptance-metadata">
                  <div :for={{key, value} <- visible_metadata(step.metadata)}>
                    <dt><%= labelize(key) %></dt>
                    <dd><%= value %></dd>
                  </div>
                </dl>
              </div>
              <div :if={terminal_surface?(step)} class="acceptance-terminal-evidence">
                <p :if={terminal_dimensions(step) != ""} class="acceptance-muted">
                  Terminal <%= terminal_dimensions(step) %>
                </p>
                <pre class="acceptance-terminal-screen"><code><%= terminal_text(step) %></code></pre>
                <ul :if={step_artifacts(step) != []} class="acceptance-artifact-list">
                  <li :for={artifact <- step_artifacts(step)}>
                    <span><%= artifact_label(artifact) %></span>
                    <code><%= artifact_path(artifact) %></code>
                  </li>
                </ul>
              </div>
              <div
                :if={message_timeline_surface?(step)}
                class={["acceptance-message-timeline", "is-#{timeline_presentation(step)}"]}
                data-channel={timeline_channel(step)}
              >
                <p class="acceptance-muted">
                  Message timeline · <%= timeline_channel(step) %>
                </p>
                <ol>
                  <li
                    :for={frame <- timeline_frames(step)}
                    class={"is-#{timeline_role(frame)}"}
                    data-operation={frame_value(frame, "operation", "observe")}
                    data-state={frame_value(frame, "state", "unknown")}
                  >
                    <p>
                      <strong><%= timeline_offset(frame) %></strong>
                      <span> · <%= frame_value(frame, "operation", "observe") %> · <%= frame_value(frame, "state", "unknown") %> · <%= timeline_role(frame) %></span>
                    </p>
                    <pre><code><%= frame_value(frame, "text", "") %></code></pre>
                  </li>
                </ol>
              </div>
              <details
                :if={step_change_status(step)}
                id={"step-#{step.id}-change-details"}
                class={"acceptance-change-details acceptance-step-change-details is-#{step_change_status(step)}"}
              >
                <summary>
                  <span class={"acceptance-change-badge is-#{step_change_status(step)}"} aria-hidden="true">
                    <.scenario_change_icon status={step_change_status(step)} />
                  </span>
                  <span>
                    <strong><%= step_change_label(step) %> step</strong>
                    <span>— What changed?</span>
                  </span>
                </summary>
                <div class="acceptance-change-details-body">
                  <p>
                    <strong><%= step_change_reason(step) %></strong>
                    <span :if={previous_run_id(@scenario_change_details)}>
                      · Compared with
                      <a href={run_path(@root_path, previous_run_id(@scenario_change_details))}>
                        <%= previous_run_id(@scenario_change_details) %>
                      </a>
                    </span>
                  </p>
                  <dl :if={step_visible_changes(step) != []} class="acceptance-change-field-list">
                    <div :for={{field, before, after_value} <- step_visible_changes(step)}>
                      <dt><%= field %></dt>
                      <dd>
                        <del><%= before %></del>
                        <span aria-hidden="true">→</span>
                        <ins><%= after_value %></ins>
                      </dd>
                    </div>
                  </dl>
                  <p :if={step_change_status(step) == "delta" && step_visible_changes(step) == []}>
                    The recorded title and description are unchanged. The scenario source changed
                    elsewhere; review the colored scenario source diff above.
                  </p>
                  <p :if={@schema_history.changes != []} class="acceptance-muted">
                    <a href={schema_domain_url(@root_path, @run_id)}>
                      Review release-level schema changes
                    </a>
                  </p>
                </div>
              </details>
              <div :if={!terminal_surface?(step) && !message_timeline_surface?(step)} class="acceptance-evidence-tabs">
                <input id={"step-#{step.id}-screenshot"} type="radio" name={"step-#{step.id}-evidence"} checked />
                <label for={"step-#{step.id}-screenshot"}>Screenshot</label>
                <input id={"step-#{step.id}-rendered"} type="radio" name={"step-#{step.id}-evidence"} />
                <label for={"step-#{step.id}-rendered"}>Rendered page</label>
                <div class="acceptance-evidence-panel acceptance-evidence-screenshot">
                  <ul :if={review_highlights(step) != []} class="acceptance-review-highlight-labels">
                    <li :for={region <- review_highlights(step)}>{region_value(region, "label")}</li>
                  </ul>
                  <a
                    :if={screenshot_name(step)}
                    class="acceptance-screenshot-link"
                    href={screenshot_path(@root_path, @run_id, screenshot_name(step))}
                    data-preview-title={step.title}
                    data-preview-context={"Step #{step_position(step, index)} · #{step.id} · #{metadata_value(step.metadata, "current_url")}"}
                    title="Open screenshot preview"
                  >
                    <img src={screenshot_path(@root_path, @run_id, screenshot_name(step))} alt={step.title} />
                    <span
                      :for={region <- review_highlights(step)}
                      class="acceptance-review-highlight"
                      style={review_highlight_style(region)}
                      aria-hidden="true"
                    ></span>
                  </a>
                  <p :if={!screenshot_name(step)} class="acceptance-empty">No screenshot was captured for this step.</p>
                </div>
                <div class="acceptance-evidence-panel acceptance-evidence-rendered">
                  <iframe
                    :if={step_page_html(step) != ""}
                    class="acceptance-rendered-page"
                    data-acceptance-rendered-page
                    sandbox="allow-scripts"
                    srcdoc={rendered_page_document(step_page_html(step), metadata_value(step.metadata, "current_url"))}
                    title={"Rendered page at #{step.title}"}
                  ></iframe>
                  <p :if={step_page_html(step) == ""} class="acceptance-empty">No page HTML was captured for this step.</p>
                </div>
              </div>
            </article>
          </section>

      </section>
      <footer class="acceptance-footer">acceptance_harness v<%= harness_version() %></footer>
    </main>
    """
  end

  defp harness_version do
    case Application.spec(:acceptance_harness, :vsn) do
      nil -> "dev"
      version -> to_string(version)
    end
  end

  defp load_scenario(socket, run_id, scenario_id) do
    socket
    |> assign(
      scenario: AdminStore.get_scenario!(run_id, scenario_id),
      run: AdminStore.get_run!(run_id),
      scenario_change_status: AdminStore.scenario_change_status(run_id, scenario_id),
      scenario_change_details: AdminStore.scenario_change_details(run_id, scenario_id),
      scenario_source_diff: AdminStore.scenario_source_diff(run_id, scenario_id),
      schema_history: AdminStore.schema_history(run_id),
      scenario_navigation: scenario_navigation(run_id, scenario_id),
      steps: AdminStore.list_steps(run_id, scenario_id)
    )
  rescue
    error ->
      assign(socket,
        error: Exception.message(error),
        scenario: nil,
        run: nil,
        scenario_change_status: nil,
        scenario_change_details: nil,
        scenario_source_diff: nil,
        schema_history: empty_schema_history(),
        scenario_navigation: nil,
        steps: []
      )
  end

  defp step_page_html(%{page_html: page_html}) when is_binary(page_html), do: page_html
  defp step_page_html(%{"page_html" => page_html}) when is_binary(page_html), do: page_html
  defp step_page_html(_step), do: ""

  defp terminal_surface?(step), do: surface_value(step, "kind") == "terminal"
  defp message_timeline_surface?(step), do: surface_value(step, "kind") == "message_timeline"

  defp terminal_text(step) do
    case surface_value(step, "text") do
      text when is_binary(text) -> text
      _value -> ""
    end
  end

  defp terminal_dimensions(step) do
    case {surface_value(step, "columns"), surface_value(step, "rows")} do
      {columns, rows} when is_integer(columns) and is_integer(rows) -> "#{columns} × #{rows}"
      _dimensions -> ""
    end
  end

  defp timeline_channel(step) do
    case surface_value(step, "channel") do
      channel when is_binary(channel) and channel != "" -> channel
      _channel -> "unspecified"
    end
  end

  defp timeline_presentation(step) do
    if String.downcase(timeline_channel(step)) == "telegram", do: "telegram", else: "generic"
  end

  defp timeline_role(frame) do
    case frame_value(frame, "role", "assistant") do
      role when role in ["user", "assistant", "system"] -> role
      _role -> "assistant"
    end
  end

  defp timeline_frames(step) do
    case surface_value(step, "frames") do
      frames when is_list(frames) -> Enum.sort_by(frames, &frame_value(&1, "at_ms", 0))
      _frames -> []
    end
  end

  defp timeline_offset(frame) do
    case frame_value(frame, "at_ms", nil) do
      value when is_integer(value) and value < 1_000 -> "+#{value} ms"
      value when is_integer(value) -> "+#{format_timeline_seconds(value)}"
      _value -> "+?"
    end
  end

  defp format_timeline_seconds(value) do
    value
    |> Kernel./(1_000)
    |> :erlang.float_to_binary(decimals: 1)
    |> String.trim_trailing(".0")
    |> Kernel.<>("s")
  end

  defp frame_value(frame, key, default) when is_map(frame) do
    Map.get(frame, key, Map.get(frame, frame_atom_key(key), default))
  end

  defp frame_value(_frame, _key, default), do: default

  defp frame_atom_key("at_ms"), do: :at_ms
  defp frame_atom_key("operation"), do: :operation
  defp frame_atom_key("state"), do: :state
  defp frame_atom_key("role"), do: :role
  defp frame_atom_key("text"), do: :text
  defp frame_atom_key(_key), do: nil

  defp surface_value(%{surface: surface}, key) when is_map(surface),
    do: Map.get(surface, key) || Map.get(surface, String.to_existing_atom(key))

  defp surface_value(%{"surface" => surface}, key) when is_map(surface),
    do: Map.get(surface, key) || Map.get(surface, String.to_existing_atom(key))

  defp surface_value(_step, _key), do: nil

  defp step_artifacts(%{artifacts: artifacts}) when is_list(artifacts), do: artifacts
  defp step_artifacts(%{"artifacts" => artifacts}) when is_list(artifacts), do: artifacts
  defp step_artifacts(_step), do: []

  defp artifact_label(artifact),
    do: Map.get(artifact, "label") || Map.get(artifact, :label) || "Artifact"

  defp artifact_path(artifact),
    do: Map.get(artifact, "path") || Map.get(artifact, :path) || ""

  # The captured page is rendered in an opaque sandbox. Its original scripts
  # and event handlers are stripped, while its CSS is preserved and resolved
  # only against the captured page's origin.
  defp rendered_page_document(page_html, page_uri) do
    page_html =
      page_html
      |> String.replace(~r/<script\b[^>]*>.*?<\/script\s*>/is, "")
      |> String.replace(~r/<script\b[^>]*\/?>/i, "")
      |> String.replace(~r/\s+on[a-z]+\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)/i, "")
      |> String.replace(
        ~r/\s+(?:href|src)\s*=\s*(?:"\s*javascript:[^"]*"|'\s*javascript:[^']*')/i,
        ""
      )

    styles =
      Regex.scan(~r/<style\b[^>]*>.*?<\/style\s*>/is, page_html)
      |> List.flatten()
      |> Enum.join("\n")

    stylesheet_links =
      Regex.scan(
        ~r/<link\b(?=[^>]*\brel\s*=\s*(?:"stylesheet"|'stylesheet'|stylesheet\b))[^>]*>/i,
        page_html
      )
      |> List.flatten()
      |> Enum.join("\n")

    page_html =
      case Regex.run(~r/<body\b[^>]*>(.*)<\/body\s*>/is, page_html) do
        [_, body] -> body
        _ -> page_html
      end

    base = rendered_page_base(page_uri)
    asset_origin = rendered_page_asset_origin(page_uri)

    """
    <!doctype html>
    <html><head>
      <meta charset="utf-8">
      #{base}
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline' #{asset_origin}; img-src data: #{asset_origin}; font-src data: #{asset_origin};">
      #{styles}
      #{stylesheet_links}
      <style>
        body { margin: 1rem; color: #1f2937; font: 16px/1.5 system-ui, sans-serif; }
      </style>
    </head><body>#{page_html}</body></html>
    """
  end

  defp rendered_page_base(page_uri) do
    case URI.parse(page_uri) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        escaped_uri = page_uri |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
        "<base href=\"#{escaped_uri}\">"

      _ ->
        ""
    end
  end

  defp rendered_page_asset_origin(page_uri) do
    case URI.parse(page_uri) do
      %URI{scheme: scheme, host: host, port: port}
      when scheme in ["http", "https"] and is_binary(host) ->
        port = if is_integer(port), do: ":#{port}", else: ""
        "#{scheme}://#{host}#{port}"

      _ ->
        "'none'"
    end
  end

  defp run_path(nil, _run_id), do: "#"

  defp run_path(root_path, run_id),
    do: "#{trim_trailing_slash(root_path)}/runs/#{URI.encode_www_form(run_id)}"

  defp scenario_path(nil, _run_id, _scenario_id), do: "#"

  defp scenario_path(root_path, run_id, scenario_id) do
    "#{run_path(root_path, run_id)}/scenarios/#{URI.encode_www_form(scenario_id)}"
  end

  defp screenshot_path(root_path, run_id, filename) do
    "#{root_path}/screenshots/#{URI.encode_www_form(run_id)}/#{URI.encode_www_form(filename)}"
  end

  defp screenshot_name(%{screenshot: %{"name" => name}}), do: name
  defp screenshot_name(%{screenshot: %{name: name}}), do: name
  defp screenshot_name(_step), do: nil

  defp review_highlights(%{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, "review_highlights") || Map.get(metadata, :review_highlights) do
      regions when is_list(regions) -> regions
      _ -> []
    end
  end

  defp review_highlights(_step), do: []

  defp review_highlight_style(region) do
    "left: #{region_number(region, "left_percent")}%; " <>
      "top: #{region_number(region, "top_percent")}%; " <>
      "width: #{region_number(region, "width_percent")}%; " <>
      "height: #{region_number(region, "height_percent")}%;"
  end

  defp region_number(region, key) do
    case region_value(region, key) do
      value when is_integer(value) or is_float(value) -> value
      _ -> 0
    end
  end

  defp region_value(region, "label") when is_map(region),
    do: Map.get(region, "label") || Map.get(region, :label)

  defp region_value(region, "left_percent") when is_map(region),
    do: Map.get(region, "left_percent") || Map.get(region, :left_percent)

  defp region_value(region, "top_percent") when is_map(region),
    do: Map.get(region, "top_percent") || Map.get(region, :top_percent)

  defp region_value(region, "width_percent") when is_map(region),
    do: Map.get(region, "width_percent") || Map.get(region, :width_percent)

  defp region_value(region, "height_percent") when is_map(region),
    do: Map.get(region, "height_percent") || Map.get(region, :height_percent)

  defp region_value(_region, _key), do: nil

  defp visible_metadata(metadata) when is_map(metadata) do
    metadata
    |> Map.take([
      "device",
      "viewport",
      "theme",
      "language",
      "user",
      "click_target"
    ])
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
  end

  defp visible_metadata(_metadata), do: []

  defp metadata_value(metadata, key) when is_binary(key) do
    if is_map(metadata) do
      metadata
      |> Map.get(key)
      |> Kernel.||("")
      |> to_string()
      |> String.trim()
    else
      ""
    end
  end

  defp scenario_values(scenario, key) when is_map(scenario) do
    values = Map.get(scenario, key) || Map.get(scenario, String.to_atom(key)) || []

    values
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 in ["", "-"]))
  end

  defp scenario_values(_scenario, _key), do: []

  defp scenario_navigation(run_id, scenario_id) do
    scenarios = AdminStore.list_scenarios(run_id)
    scenario_ids = Enum.map(scenarios, & &1.scenario_id)

    case Enum.find_index(scenario_ids, &(&1 == scenario_id)) do
      nil ->
        nil

      index ->
        %{
          position: index + 1,
          total: length(scenario_ids),
          previous: if(index > 0, do: Enum.at(scenario_ids, index - 1)),
          next: Enum.at(scenario_ids, index + 1)
        }
    end
  end

  defp scenario_failure(nil), do: nil

  defp scenario_failure(scenario) do
    case scenario["failure"] || scenario[:failure] do
      failure when is_map(failure) -> failure
      _ -> nil
    end
  end

  defp failure_pending_step(scenario) do
    case scenario_failure(scenario) do
      %{"pending_step" => %{} = pending_step} -> pending_step
      _ -> nil
    end
  end

  defp failure_screenshots(scenario) do
    case scenario_failure(scenario) do
      %{"screenshots" => screenshots} when is_list(screenshots) -> screenshots
      _ -> []
    end
  end

  defp step_failed?(scenario, step) do
    pending_step = failure_pending_step(scenario)
    screenshot = screenshot_name(step)
    pending_screenshot = pending_step_screenshot_name(pending_step)
    pending_title = pending_step_value(pending_step, "title")
    pending_id = pending_step_value(pending_step, "id")

    cond do
      screenshot && screenshot in failure_screenshots(scenario) -> true
      screenshot && pending_screenshot && screenshot == pending_screenshot -> true
      pending_id && pending_id == step_id(step) -> true
      pending_title && pending_title == step.title -> true
      true -> false
    end
  end

  defp step_id(%{id: id}), do: to_string(id)
  defp step_id(%{"id" => id}), do: to_string(id)
  defp step_id(_step), do: ""

  defp pending_step_screenshot_name(%{"screenshot_name" => name}) when is_binary(name), do: name

  defp pending_step_screenshot_name(%{"screenshot" => %{"name" => name}}) when is_binary(name),
    do: name

  defp pending_step_screenshot_name(_pending_step), do: nil

  defp pending_step_value(pending_step, key) when is_map(pending_step) do
    case Map.get(pending_step, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp pending_step_value(_pending_step, _key), do: nil

  defp failure_screenshot(scenario), do: List.first(failure_screenshots(scenario))

  defp failure_message(scenario) do
    case scenario_failure(scenario) do
      %{"message" => message} when is_binary(message) and message != "" -> message
      _ -> nil
    end
  end

  defp failure_title(scenario) do
    case scenario_failure(scenario) do
      %{"title" => title} when is_binary(title) and title != "" -> title
      _ -> "Test failed"
    end
  end

  defp failure_location(scenario) do
    case scenario_failure(scenario) do
      %{"location" => location} when is_binary(location) and location != "" -> location
      _ -> "-"
    end
  end

  defp unmatched_failure?(scenario, steps) do
    scenario_failure(scenario) && not Enum.any?(steps, &step_failed?(scenario, &1))
  end

  defp step_position(%{position: position}, _index) when is_integer(position), do: position
  defp step_position(_step, index), do: index

  defp step_export_path(root_path, step_id) do
    query = URI.encode_query(step_id: step_id, status: "all")
    "#{trim_trailing_slash(root_path)}/export.md?#{query}"
  end

  defp trim_trailing_slash(path) when is_binary(path) and path != "/" do
    String.trim_trailing(path, "/")
  end

  defp trim_trailing_slash(path), do: path

  defp labelize(nil), do: ""

  defp labelize(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp status_label("success"), do: "Passed"
  defp status_label("failure"), do: "Failed"
  defp status_label("running"), do: "Running"
  defp status_label(status) when is_binary(status), do: String.capitalize(status)
  defp status_label(_status), do: "Unknown"

  defp status_class(%{} = scenario, change_status),
    do: status_class(scenario_status(scenario), change_status)

  defp status_class("failure", _change_status), do: "is-failure"
  defp status_class("running", _change_status), do: "is-running"
  defp status_class("ignored", _change_status), do: "is-ignored"
  defp status_class("skipped", _change_status), do: "is-skipped"
  defp status_class(_status, "new"), do: "is-new"
  defp status_class(_status, "delta"), do: "is-delta"
  defp status_class(_status, _change_status), do: "is-unknown"

  defp scenario_status(%{status: status}), do: status
  defp scenario_status(%{"status" => status}), do: status
  defp scenario_status(_scenario), do: nil

  defp step_card_class(scenario, step) do
    cond do
      step_failed?(scenario, step) -> "is-failed"
      true -> step_change_class(step)
    end
  end

  defp step_change_class(%{change_status: "new"}), do: "is-new"
  defp step_change_class(%{change_status: "delta"}), do: "is-delta"
  defp step_change_class(%{"change_status" => "new"}), do: "is-new"
  defp step_change_class(%{"change_status" => "delta"}), do: "is-delta"
  defp step_change_class(_step), do: "is-unknown"

  attr(:status, :string, required: true)

  defp scenario_change_icon(assigns) do
    ~H"""
    <svg
      :if={@status == "new"}
      class="acceptance-change-icon"
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
      stroke-width="1.5"
      stroke="currentColor"
      aria-hidden="true"
    >
      <path stroke-linecap="round" stroke-linejoin="round" d="M12 9v6m3-3H9m12 0a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z" />
    </svg>
    <svg
      :if={@status == "delta"}
      class="acceptance-change-icon"
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
      stroke-width="1.5"
      stroke="currentColor"
      aria-hidden="true"
    >
      <path stroke-linecap="round" stroke-linejoin="round" d="M7.5 21 3 16.5m0 0L7.5 12M3 16.5h13.5m0-13.5L21 7.5m0 0L16.5 12M21 7.5H7.5" />
    </svg>
    """
  end

  defp scenario_change_status("new"), do: "new"
  defp scenario_change_status("delta"), do: "delta"
  defp scenario_change_status(_), do: nil

  defp scenario_change_reason("new"), do: "This scenario is new."
  defp scenario_change_reason("delta"), do: "The scenario definition changed."

  defp previous_run_id(%{} = details),
    do: Map.get(details, :previous_run_id, Map.get(details, "previous_run_id"))

  defp previous_run_id(_details), do: nil

  defp previous_title(%{} = details),
    do: Map.get(details, :previous_title, Map.get(details, "previous_title"))

  defp previous_title(_details), do: nil

  defp title_changed?(scenario, details) do
    old_title = previous_title(details)
    current_title = Map.get(scenario, "title", Map.get(scenario, :title))
    old_title not in [nil, ""] && old_title != current_title
  end

  defp changed_steps(steps) do
    Enum.filter(steps, &(step_change_status(&1) in ["new", "delta"]))
  end

  defp step_change_status(%{} = step),
    do: Map.get(step, :change_status, Map.get(step, "change_status"))

  defp step_change_label(step) do
    case step_change_status(step) do
      "new" -> "New"
      "delta" -> "Changed"
    end
  end

  defp step_change_reason(step) do
    case step_change_status(step) do
      "new" -> "This recorded step is new."
      "delta" -> "The step definition changed."
    end
  end

  defp step_visible_changes(step) do
    [
      {"Title", step_value(step, :previous_title), step_value(step, :title)},
      {"Description", step_value(step, :previous_description), step_value(step, :description)}
    ]
    |> Enum.filter(fn {_field, before, after_value} ->
      before not in [nil, ""] && before != after_value
    end)
  end

  defp step_value(%{} = step, key),
    do: Map.get(step, key, Map.get(step, Atom.to_string(key)))

  defp step_change_count_summary(steps) do
    new_count = Enum.count(steps, &(step_change_status(&1) == "new"))
    changed_count = Enum.count(steps, &(step_change_status(&1) == "delta"))
    unchanged_count = length(steps) - new_count - changed_count

    [
      pluralized_count(changed_count, "changed step", "changed steps"),
      pluralized_count(new_count, "new step", "new steps"),
      pluralized_count(unchanged_count, "unchanged step", "unchanged steps")
    ]
    |> Enum.join(" · ")
  end

  defp pluralized_count(1, singular, _plural), do: "1 #{singular}"
  defp pluralized_count(count, _singular, plural), do: "#{count} #{plural}"

  defp source_diff_marker(:added), do: "+"
  defp source_diff_marker(:removed), do: "−"
  defp source_diff_marker(:omitted), do: "⋯"
  defp source_diff_marker(_), do: " "

  defp scenario_change_aria_label(status) do
    case status do
      "new" -> "New scenario"
      "delta" -> "Changed scenario"
    end
  end

  defp scenario_change_badge_class(status), do: "is-#{status}"

  defp empty_schema_history, do: %{previous_run_id: nil, overview: nil, changes: []}

  defp schema_domain_sentence([change]), do: change.label

  defp schema_domain_sentence(changes) do
    changes
    |> Enum.map(& &1.label)
    |> Enum.join(", ")
  end

  defp schema_change_label("new"), do: "new"
  defp schema_change_label("removed"), do: "removed"
  defp schema_change_label(_), do: "changed"

  defp schema_domain_url(root_path, run_id, domain_id \\ nil) do
    base = run_path(root_path, run_id) <> "#domain-schema-changes"

    if domain_id,
      do: run_path(root_path, run_id) <> "#schema-domain-#{URI.encode_www_form(domain_id)}",
      else: base
  end
end

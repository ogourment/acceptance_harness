defmodule AcceptanceHarnessWeb.RunLive do
  @moduledoc false
  use Phoenix.LiveView

  alias AcceptanceHarness.AdminStore
  alias AcceptanceHarness.Timing
  alias AcceptanceHarnessWeb.RunFilter

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       run: nil,
       scenarios: [],
       all_scenarios: [],
       schema_history: empty_schema_history(),
       schema_diagrams: %{},
       filter: %{},
       error: nil,
       root_path: nil
     )}
  end

  def handle_params(%{"run_id" => run_id} = params, uri, socket) do
    root_path = uri |> URI.parse() |> Map.fetch!(:path) |> String.replace(~r{/runs/.*$}, "")
    filter = RunFilter.parse(params)

    socket =
      socket
      |> assign(root_path: root_path, filter: filter)
      |> load_run(run_id, filter)

    {:noreply, socket}
  end

  def handle_event("filter", params, socket) do
    filter = RunFilter.from_form(params)
    run_id = socket.assigns.run["id"] || socket.assigns.run[:id]

    {:noreply, push_patch(socket, to: run_path(socket.assigns.root_path, run_id, filter))}
  end

  def render(assigns) do
    assigns = Map.put_new(assigns, :schema_history, empty_schema_history())
    assigns = Map.put_new(assigns, :schema_diagrams, %{})

    assigns =
      Map.put_new_lazy(assigns, :timing_metrics, fn -> Timing.run_metrics(assigns.run || %{}) end)

    assigns =
      Map.put_new_lazy(assigns, :tag_timing, fn ->
        Timing.tag_summary(timing_scenarios(assigns.all_scenarios, assigns.scenarios))
      end)

    ~H"""
    <AcceptanceHarnessWeb.AdminAssets.styles />
    <AcceptanceHarnessWeb.AdminAssets.review_activity />
    <main class="acceptance-admin">
      <nav class="acceptance-breadcrumb">
        <a href={@root_path || "#"}>Acceptance reports</a>
        <span>/</span>
        <span>Run</span>
      </nav>

      <p :if={@error} class="acceptance-error"><%= @error %></p>

      <section :if={@run} class="acceptance-run" data-review-run={@run[:id] || @run["id"]} data-review-endpoint={"#{@root_path}/review-activity"}>
        <header class="acceptance-hero acceptance-run-hero" data-review-target="run">
          <div>
            <p class="acceptance-kicker"><%= app_name(@run) %> · <code><%= short_commit(app_commit(@run)) %></code></p>
            <h1><%= @run["title"] || @run[:title] %></h1>
            <p class="acceptance-lede">
              <%= length(@scenarios) %> scenarios captured. Open a scenario to inspect screenshots, rendered pages, and implementation status.
            </p>
          </div>
          <dl class="acceptance-summary-strip">
            <div class={scenario_change_box_class(@scenarios)}>
              <dt>Scenarios</dt>
              <div class="acceptance-stat-value-row">
                <dd><%= length(@scenarios) %></dd>
                <.scenario_stat_change_details
                  new_count={scenario_change_counts(@scenarios, "new")}
                  delta_count={scenario_change_counts(@scenarios, "delta")}
                  aria_label="Scenario source changes"
                />
              </div>
            </div>
            <div>
              <dt>Failed</dt>
              <dd><%= count_status(@scenarios, "failure") %></dd>
            </div>
          </dl>
        </header>

        <section id="acceptance-run-timing" class="acceptance-panel acceptance-timing-panel">
          <div class="acceptance-panel-heading">
            <div>
              <p class="acceptance-kicker">Timing</p>
              <h2>Run breakdown</h2>
            </div>
          </div>
          <dl class="acceptance-timing-grid">
            <div :for={metric <- @timing_metrics}>
              <dt><%= metric.label %></dt>
              <dd><%= metric.value %></dd>
              <small><%= metric.help %></small>
            </div>
          </dl>
          <details id="acceptance-tag-timing" class="acceptance-timing-distribution">
            <summary>Timing by ATDD tag / marker</summary>
            <p class="acceptance-muted">
              Rows overlap when a scenario has several tags. The run total above is non-overlapping.
            </p>
            <div class="acceptance-table-scroll">
              <table>
                <thead><tr><th>Tag / marker</th><th>Source</th><th>Scenarios</th><th>Steps</th><th>Step time</th></tr></thead>
                <tbody>
                  <tr :for={row <- @tag_timing}>
                    <td><code><%= if row.tag == "(untagged)", do: row.tag, else: "##{row.tag}" %></code></td>
                    <td><%= if row.tag == "(untagged)", do: "coverage gap", else: "tag" %></td>
                    <td><%= row.scenarios %></td>
                    <td><%= row.steps %></td>
                    <td><%= Timing.duration_label(row.duration_ms) %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          </details>
        </section>

        <div class="acceptance-actions">
          <a class="acceptance-button" href={"#{@root_path}/export.json?run_id=#{URI.encode_www_form(@run["id"] || @run[:id])}"}>
            Export JSON
          </a>
          <a class="acceptance-button" href={"#{@root_path}/export.md?run_id=#{URI.encode_www_form(@run["id"] || @run[:id])}"}>
            Export Markdown
          </a>
          <a
            :if={@schema_history.overview}
            class="acceptance-button"
            href={artifact_url(@root_path, @run["id"] || @run[:id], artifact_value(@schema_history.overview, "path"))}
          >
            Complete schema
          </a>
        </div>

        <section
          :if={@schema_history.changes != []}
          id="domain-schema-changes"
          class="acceptance-panel acceptance-schema-history"
        >
          <div class="acceptance-panel-heading">
            <div>
              <p class="acceptance-kicker">Release-level change</p>
              <h2>Changed domain schemas</h2>
            </div>
            <span class="acceptance-count"><%= length(@schema_history.changes) %></span>
          </div>
          <p class="acceptance-muted">
            Only domains whose generated schema changed are shown. These changes belong to the run and are not attributed to a particular scenario.
          </p>
          <div class="acceptance-schema-domain-list">
            <details
              :for={change <- @schema_history.changes}
              id={"schema-domain-#{change.domain_id}"}
              class={"acceptance-schema-domain is-#{change.status}"}
            >
              <summary>
                <a
                  class="acceptance-schema-domain-link"
                  href={
                    schema_change_artifact_url(
                      @root_path,
                      @run["id"] || @run[:id],
                      @schema_history.previous_run_id,
                      change
                    )
                  }
                >
                  <strong><%= change.label %></strong>
                </a>
                <span class="acceptance-status-pill"><%= schema_change_label(change.status) %></span>
              </summary>
              <div class="acceptance-schema-comparison">
                <%= if diagram = Map.get(@schema_diagrams, change.domain_id) do %>
                  <figure class="acceptance-schema-figure acceptance-schema-comparison-figure">
                    <figcaption>
                      Comparison — <span class="ah-legend-added">green added</span>,
                      <span class="ah-legend-removed">red removed</span>,
                      <span class="ah-legend-changed">amber changed type</span>
                    </figcaption>
                    <%= Phoenix.HTML.raw(diagram) %>
                  </figure>
                <% else %>
                  <%!-- No Graphviz, or the sources could not be read: fall back
                        to the separate diagrams rather than showing nothing. --%>
                  <.schema_figure
                    :if={change.previous}
                    title="Before"
                    run_id={@schema_history.previous_run_id}
                    artifact={change.previous}
                    root_path={@root_path}
                  />
                  <.schema_figure
                    :if={change.current}
                    title="After"
                    run_id={@run["id"] || @run[:id]}
                    artifact={change.current}
                    root_path={@root_path}
                  />
                <% end %>
              </div>
            </details>
          </div>
        </section>

        <section class="acceptance-panel acceptance-filter">
          <form phx-change="filter">
            <label>
              <span>Search</span>
              <input
                type="search"
                name="q"
                value={@filter["q"]}
                placeholder="Steps, page text, URLs…"
                phx-debounce="300"
              />
            </label>
            <label :for={{label, key, facet} <- [
              {"Value stream", "stream", :value_stream},
              {"Capability", "capability", :capability},
              {"Device", "device", :devices},
              {"Language", "language", :languages},
              {"Role", "user", :users},
              {"Tag", "tag", :tags}
            ]}>
              <span><%= label %></span>
              <select name={key}>
                <option value="">All</option>
                <option
                  :for={value <- facet_options(@all_scenarios, facet)}
                  value={value}
                  selected={@filter[key] == value}
                >
                  <%= value %>
                </option>
              </select>
            </label>
            <a :if={@filter != %{}} class="acceptance-button" href={run_path(@root_path, @run["id"] || @run[:id], %{})}>
              Clear
            </a>
          </form>
        </section>

        <section class="acceptance-panel">
          <div class="acceptance-panel-heading">
            <h2>Scenarios</h2>
            <span class="acceptance-count"><%= length(@scenarios) %><%= if length(@scenarios) != length(@all_scenarios), do: " / #{length(@all_scenarios)}" %></span>
          </div>

          <div class="acceptance-list">
            <article :for={scenario <- @scenarios} class={"acceptance-card acceptance-scenario-card #{status_class(scenario)}"}>
              <div class="acceptance-card-main">
                <p class="acceptance-card-meta">
                  <span class="acceptance-status-pill"><%= status_label(scenario.status) %></span>
                  <span><%= list_text(scenario.devices) %></span>
                  <span><%= list_text(scenario.languages) %></span>
                  <span :if={scenario[:value_stream]} class="acceptance-facet-pill">
                    Stream: <%= scenario.value_stream %>
                  </span>
                  <span :if={scenario[:capability]} class="acceptance-facet-pill">
                    Capability: <%= scenario.capability %>
                  </span>
                  <span :for={user <- facet_values(scenario.users)} class="acceptance-facet-pill">
                    Role: <%= user %>
                  </span>
                  <span :for={tag <- facet_values(scenario.tags)} class="acceptance-facet-pill">
                    Tag: <%= tag %>
                  </span>
                </p>
                <h2>
                  <a href={scenario_path(@root_path, @run["id"] || @run[:id], scenario.scenario_id)}>
                    <span
                      :if={scenario_change_status(scenario)}
                      class={"acceptance-change-badge acceptance-scenario-title-change is-#{scenario_change_status(scenario)}"}
                      aria-label={scenario_change_aria_label(scenario)}
                      title={scenario_change_aria_label(scenario)}
                    >
                      <.scenario_change_icon status={scenario_change_status(scenario)} />
                    </span>
                    <%= scenario.title %>
                  </a>
                </h2>
                <p :if={scenario[:business_outcome]} class="acceptance-muted">
                  <%= scenario.business_outcome %>
                </p>
                <p :if={scenario[:status_reason]} class="acceptance-muted acceptance-scenario-disposition">
                  <strong><%= status_label(scenario.status) %>:</strong> <%= scenario.status_reason %>
                </p>
                <p :if={scenario_change_summary_item(scenario)} class="acceptance-scenario-change-summary">
                  <span class={"acceptance-change-badge is-#{scenario_change_status(scenario)} acceptance-scenario-change-summary-icon"}>
                    <.scenario_change_icon status={scenario_change_status(scenario)} />
                  </span>
                  <span><%= scenario_change_summary_item(scenario) %></span>
                </p>
                <p :if={failure_message(scenario)} class="acceptance-scenario-failure-preview">
                  <strong>Failure:</strong> <%= failure_message(scenario) %>
                </p>
                <p class="acceptance-muted">Scenario key <code><%= scenario.scenario_id %></code></p>
                <div
                  :if={scenario_steps(scenario) != []}
                  class="acceptance-scenario-thumbnails"
                  aria-label="Scenario step screenshots"
                >
                  <a
                    :for={{step, index} <- Enum.with_index(scenario_steps(scenario), 1)}
                    class={"acceptance-step-thumbnail #{step_card_class(scenario, step)}"}
                    href={scenario_step_path(@root_path, @run["id"] || @run[:id], scenario.scenario_id, step)}
                    title={"Step #{step_position(step, index)}: #{step_title(step)}"}
                    aria-label={"Open step #{step_position(step, index)}: #{step_title(step)}"}
                  >
                    <img
                      :if={screenshot_name(step)}
                      src={screenshot_path(@root_path, @run["id"] || @run[:id], screenshot_name(step))}
                      alt=""
                      loading="lazy"
                    />
                    <span :if={!screenshot_name(step)} class="acceptance-step-thumbnail-empty">
                      <%= step_position(step, index) %>
                    </span>
                    <span class="acceptance-step-thumbnail-index"><%= step_position(step, index) %></span>
                  </a>
                </div>
                <a
                  :if={failure_screenshot(scenario)}
                  class="acceptance-failure-thumbnail"
                  href={scenario_path(@root_path, @run["id"] || @run[:id], scenario.scenario_id) <> "#scenario-failure"}
                  title="Open failure details and screenshot"
                >
                  <img
                    src={screenshot_path(@root_path, @run["id"] || @run[:id], failure_screenshot(scenario))}
                    alt="Failure screenshot"
                    loading="lazy"
                  />
                </a>
              </div>
              <dl class="acceptance-stats">
                <div>
                  <dt>Evidence time</dt>
                  <dd><%= duration_label(scenario.documented_step_ms || 0) %></dd>
                </div>
              </dl>
            </article>
          </div>
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

  defp duration_label(milliseconds) when milliseconds < 1_000,
    do: "#{milliseconds} ms"

  defp duration_label(milliseconds) when milliseconds < 60_000 do
    seconds = Float.round(milliseconds / 1_000, 1)
    "#{format_decimal(seconds)} s"
  end

  defp duration_label(milliseconds) do
    total_seconds = round(milliseconds / 1_000)
    minutes = div(total_seconds, 60)
    seconds = rem(total_seconds, 60)

    if seconds == 0, do: "#{minutes} min", else: "#{minutes} min #{seconds} s"
  end

  defp format_decimal(value) do
    if value == trunc(value), do: Integer.to_string(trunc(value)), else: Float.to_string(value)
  end

  defp load_run(socket, run_id, filter) do
    all_scenarios = AdminStore.list_scenarios(run_id)

    scenarios =
      case RunFilter.to_store_opts(filter) do
        [] -> all_scenarios
        store_opts -> AdminStore.list_scenarios(run_id, store_opts)
      end

    schema_history = AdminStore.schema_history(run_id)

    assign(socket,
      run: AdminStore.get_run!(run_id),
      scenarios: scenarios,
      all_scenarios: all_scenarios,
      timing_metrics: Timing.run_metrics(AdminStore.get_run!(run_id)),
      tag_timing: Timing.tag_summary(all_scenarios),
      schema_history: schema_history,
      schema_diagrams:
        AcceptanceHarness.SchemaHistory.union_diagrams(
          schema_history.changes,
          run_id,
          schema_history.previous_run_id
        )
    )
  rescue
    error ->
      assign(socket,
        error: Exception.message(error),
        run: nil,
        scenarios: [],
        all_scenarios: [],
        schema_history: empty_schema_history(),
        schema_diagrams: %{},
        schema_diagrams: %{}
      )
  end

  attr(:title, :string, required: true)
  attr(:run_id, :string, required: true)
  attr(:artifact, :map, required: true)
  attr(:root_path, :string, required: true)

  defp schema_figure(assigns) do
    ~H"""
    <figure class="acceptance-schema-figure">
      <figcaption><%= @title %></figcaption>
      <a href={artifact_url(@root_path, @run_id, artifact_value(@artifact, "path"))}>
        <img
          src={artifact_url(@root_path, @run_id, artifact_value(@artifact, "path"))}
          alt={"#{artifact_value(@artifact, "label")} schema — #{@title}"}
          loading="lazy"
        />
      </a>
      <a
        :if={artifact_value(@artifact, "dot_path")}
        class="acceptance-schema-source"
        href={artifact_url(@root_path, @run_id, artifact_value(@artifact, "dot_path"))}
      >
        DOT source
      </a>
    </figure>
    """
  end

  defp empty_schema_history, do: %{previous_run_id: nil, overview: nil, changes: []}

  defp timing_scenarios([], visible_scenarios), do: visible_scenarios
  defp timing_scenarios(nil, visible_scenarios), do: visible_scenarios
  defp timing_scenarios(all_scenarios, _visible_scenarios), do: all_scenarios

  defp schema_change_label("new"), do: "New"
  defp schema_change_label("removed"), do: "Removed"
  defp schema_change_label(_), do: "Changed"

  defp schema_change_artifact_url(root_path, current_run_id, previous_run_id, change) do
    case change.current do
      current when is_map(current) ->
        artifact_url(root_path, current_run_id, artifact_value(current, "path"))

      nil ->
        artifact_url(root_path, previous_run_id, artifact_value(change.previous, "path"))
    end
  end

  defp artifact_url(root_path, run_id, relative_path) do
    encoded_path =
      relative_path
      |> to_string()
      |> String.split("/", trim: true)
      |> Enum.map_join("/", &URI.encode_www_form/1)

    "#{trim_trailing_slash(root_path)}/artifacts/#{URI.encode_www_form(run_id)}/#{encoded_path}"
  end

  defp artifact_value(artifact, key) when is_map(artifact) do
    Map.get(artifact, key) || Map.get(artifact, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(artifact, key)
  end

  defp run_path(root_path, run_id, filter) do
    base = "#{trim_trailing_slash(root_path)}/runs/#{URI.encode_www_form(run_id)}"

    case RunFilter.encode(filter) do
      nil -> base
      encoded -> base <> "?filter=" <> URI.encode_www_form(encoded)
    end
  end

  defp facet_options(scenarios, key) do
    scenarios
    |> Enum.flat_map(&List.wrap(Map.get(&1, key)))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp scenario_path(root_path, run_id, scenario_id) do
    "#{trim_trailing_slash(root_path)}/runs/#{URI.encode_www_form(run_id)}/scenarios/#{URI.encode_www_form(scenario_id)}"
  end

  defp scenario_step_path(root_path, run_id, scenario_id, step) do
    "#{scenario_path(root_path, run_id, scenario_id)}#step-#{URI.encode_www_form(step_id(step))}"
  end

  defp screenshot_path(root_path, run_id, filename) do
    "#{trim_trailing_slash(root_path)}/screenshots/#{URI.encode_www_form(run_id)}/#{URI.encode_www_form(filename)}?variant=thumbnail"
  end

  defp scenario_steps(%{steps: steps}) when is_list(steps), do: steps
  defp scenario_steps(%{"steps" => steps}) when is_list(steps), do: steps
  defp scenario_steps(_scenario), do: []

  defp step_id(%{id: id}), do: to_string(id)
  defp step_id(%{"id" => id}), do: to_string(id)
  defp step_id(_step), do: ""

  defp step_title(%{title: title}) when is_binary(title), do: title
  defp step_title(%{"title" => title}) when is_binary(title), do: title
  defp step_title(_step), do: "Step"

  defp step_position(%{position: position}, _index) when is_integer(position), do: position
  defp step_position(%{"position" => position}, _index) when is_integer(position), do: position
  defp step_position(%{sequence: sequence}, _index) when is_integer(sequence), do: sequence
  defp step_position(%{"sequence" => sequence}, _index) when is_integer(sequence), do: sequence
  defp step_position(_step, index), do: index

  defp screenshot_name(%{screenshot: %{"name" => name}}) when is_binary(name), do: name
  defp screenshot_name(%{screenshot: %{name: name}}) when is_binary(name), do: name
  defp screenshot_name(%{"screenshot" => %{"name" => name}}) when is_binary(name), do: name
  defp screenshot_name(_step), do: nil

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
      pending_title && pending_title == step_title(step) -> true
      true -> false
    end
  end

  defp scenario_failure(nil), do: nil

  defp scenario_failure(scenario) do
    case scenario[:failure] || scenario["failure"] do
      failure when is_map(failure) -> failure
      _ -> nil
    end
  end

  defp failure_pending_step(scenario) do
    case scenario_failure(scenario) do
      %{"pending_step" => %{} = pending_step} -> pending_step
      %{pending_step: %{} = pending_step} -> pending_step
      _ -> nil
    end
  end

  defp failure_screenshots(scenario) do
    case scenario_failure(scenario) do
      %{"screenshots" => screenshots} when is_list(screenshots) -> screenshots
      %{screenshots: screenshots} when is_list(screenshots) -> screenshots
      _ -> []
    end
  end

  defp failure_screenshot(scenario) do
    List.first(failure_screenshots(scenario))
  end

  defp failure_message(scenario) do
    case scenario_failure(scenario) do
      %{"message" => message} when is_binary(message) and message != "" -> message
      %{message: message} when is_binary(message) and message != "" -> message
      _ -> nil
    end
  end

  defp pending_step_screenshot_name(%{"screenshot_name" => name}) when is_binary(name), do: name
  defp pending_step_screenshot_name(%{screenshot_name: name}) when is_binary(name), do: name

  defp pending_step_screenshot_name(%{"screenshot" => %{"name" => name}}) when is_binary(name),
    do: name

  defp pending_step_screenshot_name(%{screenshot: %{name: name}}) when is_binary(name), do: name
  defp pending_step_screenshot_name(_pending_step), do: nil

  defp pending_step_value(pending_step, key) when is_map(pending_step) do
    case Map.get(pending_step, key) || Map.get(pending_step, pending_step_atom_key(key)) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp pending_step_value(_pending_step, _key), do: nil

  defp pending_step_atom_key("id"), do: :id
  defp pending_step_atom_key("title"), do: :title
  defp pending_step_atom_key(_key), do: nil

  defp scenario_change_box_class(scenarios) do
    scenario_change_box_class(
      scenario_change_counts(scenarios, "new"),
      scenario_change_counts(scenarios, "delta")
    )
  end

  defp scenario_change_counts(scenarios, status) when is_list(scenarios) do
    Enum.count(scenarios, &(scenario_change_status(&1) == status))
  end

  defp scenario_change_counts(_scenarios, _status), do: 0

  defp scenario_change_box_class(new_count, _delta_count)
       when is_integer(new_count) and new_count > 0 do
    "is-new"
  end

  defp scenario_change_box_class(_new_count, delta_count)
       when is_integer(delta_count) and delta_count > 0 do
    "is-delta"
  end

  defp scenario_change_box_class(_new_count, _delta_count), do: nil

  defp scenario_change_status(%{change_status: status}) when status in ["new", "delta"],
    do: status

  defp scenario_change_status(%{"change_status" => status}) when status in ["new", "delta"],
    do: status

  defp scenario_change_status(_scenario), do: nil

  defp scenario_change_aria_label(scenario) do
    case scenario_change_status(scenario) do
      "new" -> "New scenario"
      "delta" -> "Changed scenario"
    end
  end

  defp scenario_change_summary_item(scenario) do
    status = scenario_change_status(scenario)

    if status in ["new", "delta"] do
      base_summary =
        case {status, scenario_previous_title(scenario), scenario_title(scenario)} do
          {"new", _, current_title} ->
            "New: #{current_title}"

          {"delta", previous_title, current_title}
          when is_binary(previous_title) and previous_title != "" and
                 previous_title != current_title ->
            "Renamed: #{previous_title} -> #{current_title}"

          {"delta", _, _current_title} ->
            "Updated"
        end

      base_summary =
        if status == "delta" do
          "#{base_summary} · #{scenario_step_change_summary(scenario)}"
        else
          base_summary
        end

      base_summary
    end
  end

  defp scenario_step_change_summary(scenario) do
    steps = scenario_steps(scenario)
    new_count = Enum.count(steps, &(step_change_status(&1) == "new"))
    changed_count = Enum.count(steps, &(step_change_status(&1) == "delta"))

    case {new_count, changed_count} do
      {0, 0} ->
        "No recorded step changed"

      {new_count, 0} ->
        pluralized_step_count(new_count, "new")

      {0, changed_count} ->
        pluralized_step_count(changed_count, "changed")

      {new_count, changed_count} ->
        "#{pluralized_step_count(new_count, "new")}, " <>
          pluralized_step_count(changed_count, "changed")
    end
  end

  defp pluralized_step_count(1, status), do: "1 #{status} recorded step"
  defp pluralized_step_count(count, status), do: "#{count} #{status} recorded steps"

  defp step_change_status(%{change_status: status}), do: status
  defp step_change_status(%{"change_status" => status}), do: status
  defp step_change_status(_step), do: nil

  defp scenario_previous_title(%{previous_title: title}), do: title
  defp scenario_previous_title(%{"previous_title" => title}), do: title
  defp scenario_previous_title(_), do: nil

  defp scenario_title(%{title: title}), do: title
  defp scenario_title(%{"title" => title}), do: title
  defp scenario_title(_), do: ""

  attr(:new_count, :integer, required: true)
  attr(:delta_count, :integer, required: true)
  attr(:aria_label, :string, required: true)

  defp scenario_stat_change_details(assigns) do
    ~H"""
    <div class="acceptance-stat-change-details" aria-label={@aria_label}>
      <span class="acceptance-stat-change-item">
        <span class="acceptance-change-badge is-new" title="New">
          <.scenario_change_icon status="new" />
        </span>
        <%= @new_count %>
      </span>
      <span class="acceptance-stat-change-item">
        <span class="acceptance-change-badge is-delta" title="Delta">
          <.scenario_change_icon status="delta" />
        </span>
        <%= @delta_count %>
      </span>
    </div>
    """
  end

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

  defp trim_trailing_slash(path) when is_binary(path) and path != "/" do
    String.trim_trailing(path, "/")
  end

  defp trim_trailing_slash(path), do: path

  defp app_name(run),
    do:
      get_in(run, ["app", "name"]) || get_in(run, [:app, "name"]) || get_in(run, [:app, :name]) ||
        "App"

  defp app_commit(run),
    do:
      get_in(run, ["app", "commit"]) || get_in(run, [:app, "commit"]) ||
        get_in(run, [:app, :commit]) || "unknown"

  defp short_commit(""), do: "unknown"
  defp short_commit(commit) when is_binary(commit), do: String.slice(commit, 0, 12)
  defp short_commit(_commit), do: "unknown"

  defp count_status(scenarios, status), do: Enum.count(scenarios, &(&1.status == status))

  defp list_text(nil), do: "-"
  defp list_text([]), do: "-"
  defp list_text(values) when is_list(values), do: Enum.join(values, ", ")
  defp list_text(value), do: to_string(value)

  defp facet_values(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 in ["", "-"]))
  end

  defp facet_values(_values), do: []

  defp status_label("success"), do: "Passed"
  defp status_label("failure"), do: "Failed"
  defp status_label("running"), do: "Running"
  defp status_label("ignored"), do: "Ignored"
  defp status_label("skipped"), do: "Skipped"
  defp status_label(status) when is_binary(status), do: String.capitalize(status)
  defp status_label(_status), do: "Unknown"

  defp status_class(%{} = scenario) do
    status_class(scenario_status(scenario), scenario_change_status(scenario))
  end

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
end

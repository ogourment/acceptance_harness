defmodule AcceptanceHarnessWeb.RunIndexLive do
  @moduledoc false
  use Phoenix.LiveView

  require Logger

  alias AcceptanceHarness.{AdminStore, Config}

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       runs: [],
       error: nil,
       info: nil,
       deployment_query: nil,
       root_path: nil,
       versions_path: Config.admin_versions_path(),
       admin_actions: Config.admin_actions()
     )}
  end

  def handle_params(params, uri, socket) do
    deployment_query = present_param(params["deployment"])

    socket =
      socket
      |> assign(:deployment_query, deployment_query)
      |> assign(:root_path, URI.parse(uri).path)
      |> load_runs(deployment_query)

    {:noreply, socket}
  end

  def render(assigns) do
    assigns =
      assigns
      |> Map.put_new(:admin_actions, [])
      |> Map.put_new(:info, nil)
      |> Map.put_new(:deployment_query, nil)

    ~H"""
    <AcceptanceHarnessWeb.AdminAssets.styles />
    <main class="acceptance-admin">
      <header class="acceptance-hero">
        <div>
          <p class="acceptance-kicker">Acceptance evidence</p>
          <h1>Review runs</h1>
          <p class="acceptance-lede">Open the latest captured evidence by scenario and step.</p>
        </div>
        <dl class="acceptance-summary-strip">
          <div>
            <dt>Runs</dt>
            <dd><%= length(@runs) %></dd>
          </div>
        </dl>
      </header>

      <nav
        :if={@versions_path || @admin_actions != []}
        class="acceptance-actions"
        aria-label="Related admin pages"
      >
        <a :if={@versions_path} class="acceptance-button" href={@versions_path}>
          Deployment versions
        </a>
        <span :if={@admin_actions != []} class="acceptance-maintenance" aria-label="Maintenance actions">
          <button
            :for={action <- @admin_actions}
            id={"acceptance-action-" <> action.id}
            type="button"
            class="acceptance-button acceptance-button-quiet"
            phx-click="run_admin_action"
            phx-value-id={action.id}
            data-confirm={action.confirm}
            title={action.description}
          >
            <%= action.label %>
          </button>
        </span>
      </nav>

      <p :if={@info} class="acceptance-flash"><%= @info %></p>
      <p :if={@error} class="acceptance-error"><%= @error %></p>

      <section class="acceptance-panel">
        <div class="acceptance-panel-heading">
          <h2>
            <%= if @deployment_query,
              do: "Acceptance results for deployment #{@deployment_query}",
              else: "Imported reports" %>
          </h2>
          <span class="acceptance-count"><%= length(@runs) %></span>
        </div>

        <p :if={@runs == [] and is_nil(@error)} class="acceptance-empty">No acceptance runs imported yet.</p>

        <div class="acceptance-list">
          <article :for={run <- @runs} class={"acceptance-card acceptance-run-card #{run_card_class(run)}"}>
            <div class="acceptance-card-main">
              <p class="acceptance-card-meta">
                <%= app_name(run) %>
                <span :if={app_version(run)}>· <code>v<%= app_version(run) %></code></span>
                · <code><%= short_commit(app_commit(run)) %></code>
              </p>
            <h2>
              <a href={run_path(@root_path, run.id)}><%= run.title %></a>
            </h2>
              <p class="acceptance-muted">Finalized <%= format_datetime(run.finalized_at || run.generated_at) %></p>
            </div>
            <dl class="acceptance-stats">
              <div class={scenario_change_box_class(run[:new_scenario_count] || 0, run[:delta_scenario_count] || 0)}>
                <dt>Scenarios</dt>
                <div class="acceptance-stat-value-row">
                  <dd><%= run.scenario_count %></dd>
                  <.stat_change_details
                    new_count={run[:new_scenario_count] || 0}
                    delta_count={run[:delta_scenario_count] || 0}
                    aria_label="Scenario source changes"
                  />
                </div>
              </div>
              <div class={if (run[:failure_count] || 0) > 0, do: "is-failure"}>
                <dt>Failures</dt>
                <div class="acceptance-stat-value-row">
                  <dd><%= run[:failure_count] || 0 %></dd>
                  <span :if={run[:recovered]} class="acceptance-recovered-pill" title="Passed after the previous run failed">
                    <svg viewBox="0 0 16 16" fill="none" aria-hidden="true" focusable="false">
                      <path
                        d="M13 4.5 6.5 11 3 7.5"
                        stroke="currentColor"
                        stroke-width="2"
                        stroke-linecap="round"
                        stroke-linejoin="round"
                      />
                    </svg>
                    recovered
                  </span>
                </div>
              </div>
              <div class={if (run[:schema_domain_change_count] || 0) > 0, do: "is-attention"}>
                <dt>Schema domains</dt>
                <dd><%= run[:schema_domain_change_count] || 0 %></dd>
              </div>
            </dl>
            <details
              :if={run_changes?(run)}
              id={"run-#{run.id}-change-details"}
              class={"acceptance-change-details acceptance-run-change-details is-#{run_change_status(run)}"}
            >
              <summary>
                <span class={"acceptance-change-badge is-#{run_change_status(run)}"} aria-hidden="true">
                  <.change_icon status={run_change_status(run)} />
                </span>
                <span>
                  <strong>Run changes</strong>
                  <span>— What changed?</span>
                </span>
              </summary>
              <div class="acceptance-change-details-body">
                <ul class="acceptance-run-change-list">
                  <li :for={item <- run_change_items(run)}><%= item %></li>
                  <li :if={(run[:changed_schema_domain_refs] || []) != []}>
                    <%= schema_domain_count(run[:changed_schema_domain_refs]) %>:
                    <.link
                      :for={{domain, index} <- Enum.with_index(run[:changed_schema_domain_refs])}
                      navigate={schema_domain_path(@root_path, run[:id] || run["id"], domain.id)}
                      class="acceptance-schema-domain-link"
                    ><%= if index > 0, do: ", " %><%= domain.label %></.link>
                  </li>
                </ul>
                <ul
                  :if={(run[:changed_scenarios] || []) != []}
                  class="acceptance-run-changed-scenarios"
                >
                  <li :for={scenario <- run[:changed_scenarios] || []}>
                    <span class={"acceptance-change-badge is-#{scenario.status}"} aria-hidden="true">
                      <.change_icon status={scenario.status} />
                    </span>
                    <a href={scenario_path(@root_path, run.id, scenario.scenario_id)}>
                      <%= scenario.title %>
                    </a>
                  </li>
                </ul>
              </div>
            </details>
          </article>
        </div>
      </section>
      <footer class="acceptance-footer">acceptance_harness v<%= harness_version() %></footer>
    </main>
    """
  end

  def handle_event("run_admin_action", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.admin_actions, &(&1.id == id)) do
      nil ->
        {:noreply, assign(socket, error: "Unknown maintenance action.", info: nil)}

      action ->
        run_admin_action(action, socket)
    end
  end

  defp run_admin_action(%{run: {module, function, args}}, socket) do
    case apply(module, function, args) do
      {:ok, message} ->
        {:noreply, socket |> assign(info: message, error: nil) |> load_runs()}

      {:error, message} ->
        {:noreply, assign(socket, error: message, info: nil)}

      _other ->
        {:noreply, socket |> assign(info: "Action finished.", error: nil) |> load_runs()}
    end
  rescue
    error ->
      message = "Action failed: #{Exception.message(error)}"
      Logger.error(message)
      {:noreply, assign(socket, error: message, info: nil)}
  end

  defp harness_version do
    case Application.spec(:acceptance_harness, :vsn) do
      nil -> "dev"
      version -> to_string(version)
    end
  end

  attr(:new_count, :integer, required: true)
  attr(:delta_count, :integer, required: true)
  attr(:aria_label, :string, required: true)

  defp stat_change_details(assigns) do
    ~H"""
    <div class="acceptance-stat-change-details" aria-label={@aria_label}>
      <span class="acceptance-stat-change-item">
        <span class="acceptance-change-badge is-new" title="New">
          <.change_icon status="new" />
        </span>
        <%= @new_count %>
      </span>
      <span class="acceptance-stat-change-item">
        <span class="acceptance-change-badge is-delta" title="Delta">
          <.change_icon status="delta" />
        </span>
        <%= @delta_count %>
      </span>
    </div>
    """
  end

  defp scenario_change_box_class(new_count, _delta_count)
       when is_integer(new_count) and new_count > 0 do
    "is-new"
  end

  defp scenario_change_box_class(_new_count, delta_count)
       when is_integer(delta_count) and delta_count > 0 do
    "is-delta"
  end

  defp scenario_change_box_class(_new_count, _delta_count), do: nil

  defp run_card_class(run) do
    cond do
      (run[:failure_count] || 0) > 0 -> "is-failure"
      (run[:new_scenario_count] || 0) > 0 -> "is-new"
      (run[:new_step_count] || 0) > 0 -> "is-new"
      (run[:schema_domain_change_count] || 0) > 0 -> "is-delta"
      (run[:delta_scenario_count] || 0) > 0 -> "is-delta"
      (run[:delta_step_count] || 0) > 0 -> "is-delta"
      true -> "is-unknown"
    end
  end

  # Schema domains are rendered as links rather than as a text item, so they
  # must be counted here explicitly or a run whose only change is a schema
  # change would show no change block at all.
  defp run_changes?(run) do
    run_change_items(run) != [] or (run[:changed_schema_domain_refs] || []) != []
  end

  defp run_change_status(run) do
    if (run[:new_scenario_count] || 0) > 0 || (run[:new_step_count] || 0) > 0,
      do: "new",
      else: "delta"
  end

  defp run_change_items(run) do
    [
      count_item(run[:new_scenario_count] || 0, "new scenario", "new scenarios"),
      count_item(run[:delta_scenario_count] || 0, "changed scenario", "changed scenarios"),
      count_item(run[:new_step_count] || 0, "new recorded step", "new recorded steps"),
      count_item(run[:delta_step_count] || 0, "changed recorded step", "changed recorded steps")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp count_item(0, _singular, _plural), do: nil
  defp count_item(1, singular, _plural), do: "1 #{singular}"
  defp count_item(count, _singular, plural), do: "#{count} #{plural}"

  defp schema_domain_count(domains) do
    count_item(length(domains), "domain schema", "domain schemas")
  end

  # Anchors the comparison the reviewer clicked, not just the section.
  defp schema_domain_path(root_path, run_id, domain_id) do
    run_path(root_path, run_id) <> "#schema-domain-" <> domain_id
  end

  defp scenario_path(root_path, run_id, scenario_id) do
    run_path(root_path, run_id) <> "/scenarios/" <> URI.encode_www_form(scenario_id)
  end

  attr(:status, :string, required: true)

  defp change_icon(assigns) do
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

  defp load_runs(socket), do: load_runs(socket, socket.assigns[:deployment_query])

  defp load_runs(socket, deployment_query) do
    runs =
      AdminStore.list_runs(limit: if(deployment_query, do: 200, else: 20))
      |> filter_deployment_runs(deployment_query)

    assign(socket, runs: runs)
  rescue
    error -> assign(socket, error: Exception.message(error), runs: [])
  end

  defp filter_deployment_runs(runs, nil), do: runs

  defp filter_deployment_runs(runs, query) do
    Enum.filter(runs, fn run ->
      app = run[:app] || %{}

      Enum.any?(
        [
          app["pipeline_id"],
          app[:pipeline_id],
          app["commit"],
          app[:commit],
          app["release_id"],
          app[:release_id]
        ],
        &(is_binary(&1) and &1 == query)
      )
    end)
  end

  defp present_param(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      present -> present
    end
  end

  defp present_param(_value), do: nil

  defp run_path(root_path, run_id), do: "#{root_path}/runs/#{URI.encode_www_form(run_id)}"

  defp app_name(run), do: get_in(run, [:app, "name"]) || get_in(run, [:app, :name]) || "App"

  # Runs recorded before the release version was captured have none. Showing
  # nothing is honest; showing "unknown" beside a real commit is not.
  defp app_version(run) do
    case get_in(run, [:app, "version"]) || get_in(run, [:app, :version]) do
      version when is_binary(version) and version != "" -> version
      _ -> nil
    end
  end

  defp app_commit(run),
    do: get_in(run, [:app, "commit"]) || get_in(run, [:app, :commit]) || "unknown"

  defp short_commit(""), do: "unknown"
  defp short_commit(commit) when is_binary(commit), do: String.slice(commit, 0, 12)
  defp short_commit(_commit), do: "unknown"

  defp format_datetime(nil), do: "unknown"

  defp format_datetime(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  end

  defp format_datetime(%NaiveDateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
  end

  defp format_datetime(value), do: to_string(value)
end

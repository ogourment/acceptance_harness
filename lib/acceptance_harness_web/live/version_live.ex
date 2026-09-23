defmodule AcceptanceHarnessWeb.VersionLive do
  @moduledoc false
  use Phoenix.LiveView

  alias AcceptanceHarness.{AdminStore, Config, Deployment}

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       rows: [],
       query: "",
       page: 1,
       page_size: 10,
       total: 0,
       total_pages: 1,
       root_path: nil,
       acceptance_path: Config.admin_acceptance_path(),
       version_groups: [],
       production_comparison: nil,
       peer_versions_url: peer_versions_url(),
       peer_acceptance_url: peer_acceptance_url()
     )}
  end

  def handle_params(params, uri, socket) do
    page = Deployment.list(params)

    rows =
      acceptance_links(
        page.rows,
        socket.assigns.acceptance_path,
        socket.assigns.peer_acceptance_url
      )

    all_rows =
      acceptance_links(
        Deployment.rows(),
        socket.assigns.acceptance_path,
        socket.assigns.peer_acceptance_url
      )

    {:noreply,
     socket
     |> assign(Map.to_list(%{page | rows: rows}))
     |> assign(:version_groups, group_by_version(rows))
     |> assign(:production_comparison, production_comparison(all_rows))
     |> assign(:root_path, URI.parse(uri).path)}
  end

  def handle_event("search", %{"search" => %{"q" => query}}, socket) do
    {:noreply, push_patch(socket, to: page_path(socket.assigns.root_path, query, 1))}
  end

  def render(assigns) do
    assigns = Map.put_new(assigns, :peer_acceptance_url, nil)

    ~H"""
    <AcceptanceHarnessWeb.AdminAssets.styles />
    <main class="acceptance-admin acceptance-versions-admin">
      <header class="acceptance-hero">
        <div>
          <p class="acceptance-kicker">Release operations</p>
          <h1>Deployment versions</h1>
          <p class="acceptance-lede">
            Inspect the running release and deployment history. Search by version, release,
            environment, ref, commit hash, or commit message.
          </p>
        </div>
        <div class="acceptance-actions acceptance-hero-actions">
          <a :if={@acceptance_path} class="acceptance-button" href={@acceptance_path}>
            Acceptance evidence
          </a>
        </div>
      </header>

      <section class="acceptance-panel acceptance-version-controls">
        <form id="deployment-version-search-form" phx-change="search" phx-submit="search">
          <label for="deployment-version-search">Search deployments</label>
          <input
            id="deployment-version-search"
            type="search"
            name="search[q]"
            value={@query}
            placeholder="Version, partial SHA, or commit message"
            phx-debounce="250"
          />
        </form>
        <p class="acceptance-muted">
          <%= result_summary(@total, @query) %>
        </p>
      </section>

      <section
        :if={@production_comparison}
        class="acceptance-panel acceptance-production-comparison"
        aria-labelledby="production-comparison-title"
      >
        <div class="acceptance-version-section-heading">
          <div>
            <p class="acceptance-kicker">Production comparison</p>
            <h2 id="production-comparison-title">Running and previous production releases</h2>
          </div>
          <a
            :if={staging_version_url(@production_comparison.current, @peer_versions_url)}
            class="acceptance-button"
            href={staging_version_url(@production_comparison.current, @peer_versions_url)}
          >
            View this version in staging
          </a>
        </div>
        <div class="acceptance-version-comparison-grid">
          <.comparison_release
            label="Running production"
            row={@production_comparison.current}
          />
          <.comparison_release
            label="Previous production"
            row={@production_comparison.previous}
          />
        </div>
      </section>

      <section class="acceptance-panel">
        <div class="acceptance-list acceptance-version-list">
          <section
            :for={{version, rows} <- @version_groups}
            class="acceptance-version-group"
            data-version-group={version}
          >
            <h2><%= version_group_label(version) %></h2>
            <.version_card :for={row <- rows} row={row} />
          </section>

          <p :if={@rows == []} class="acceptance-empty">
            No deployments match<%= if @query == "", do: ".", else: " “#{@query}”." %>
          </p>
        </div>
      </section>

      <nav :if={@total_pages > 1} class="acceptance-pagination" aria-label="Deployment history pages">
        <.link
          :if={@page > 1}
          patch={page_path(@root_path, @query, @page - 1)}
          class="acceptance-button"
        >
          Previous
        </.link>
        <span>Page <%= @page %> of <%= @total_pages %></span>
        <.link
          :if={@page < @total_pages}
          patch={page_path(@root_path, @query, @page + 1)}
          class="acceptance-button"
        >
          Next
        </.link>
      </nav>

      <footer class="acceptance-footer">acceptance_harness v<%= harness_version() %></footer>
    </main>
    """
  end

  defp version_card(assigns) do
    ~H"""
    <article class="acceptance-card acceptance-version-card">
      <div class="acceptance-version-heading">
        <div>
          <p class="acceptance-card-meta">
            <span :if={@row["current"]} class="acceptance-status-pill">Current</span>
            <span :if={@row["version_only"]} class="acceptance-status-pill">Version history</span>
            <span :if={!@row["version_only"]}>
              <%= empty_dash(@row["environment"]) %> · <%= empty_dash(@row["slot"]) %>
            </span>
          </p>
          <h3><%= version_label(@row) %></h3>
        </div>
        <code><%= short_sha(@row["git_sha"]) %></code>
      </div>

      <dl class="acceptance-version-grid">
        <div :if={!@row["version_only"]}>
          <dt>Release</dt><dd><%= empty_dash(@row["release_id"]) %></dd>
        </div>
        <div :if={!@row["version_only"]}>
          <dt>Pipeline</dt><dd><%= empty_dash(@row["pipeline_id"]) %></dd>
        </div>
        <div :if={!@row["version_only"]}>
          <dt>Git ref</dt><dd><%= empty_dash(@row["git_ref"]) %></dd>
        </div>
        <div>
          <dt><%= if @row["version_only"], do: "Committed", else: "Deployed at" %></dt>
          <dd><%= empty_dash(@row[if(@row["version_only"], do: "committed_at", else: "deployed_at")]) %></dd>
        </div>
      </dl>

      <div class="acceptance-version-messages">
        <h3>Commits</h3>
        <ul :if={git_messages(@row) != []}>
          <li :for={{sha, message} <- parsed_git_messages(@row)}>
            <code :if={sha}><%= sha %></code>
            <span><%= message %></span>
          </li>
        </ul>
        <p :if={git_messages(@row) == []} class="acceptance-muted">No commits recorded.</p>
      </div>

      <nav
        :if={@row["acceptance_live_url"] || @row["acceptance_static_url"]}
        class="acceptance-actions"
        aria-label="Acceptance results for this release"
      >
        <a
          :if={@row["acceptance_live_url"]}
          class="acceptance-button"
          href={@row["acceptance_live_url"]}
        >
          Live acceptance
        </a>
        <a
          :if={@row["acceptance_static_url"]}
          class="acceptance-button"
          href={@row["acceptance_static_url"]}
        >
          Static report
        </a>
      </nav>
    </article>
    """
  end

  defp comparison_release(assigns) do
    ~H"""
    <article class="acceptance-card acceptance-version-comparison-card">
      <p class="acceptance-card-meta"><%= @label %></p>
      <div class="acceptance-version-heading">
        <h3><%= version_label(@row) %></h3>
        <code><%= short_sha(@row["git_sha"]) %></code>
      </div>
      <p><%= empty_dash(@row["release_id"]) %></p>
      <p class="acceptance-muted">
        Pipeline <%= empty_dash(@row["pipeline_id"]) %> ·
        <%= empty_dash(@row["deployed_at"]) %>
      </p>
    </article>
    """
  end

  defp page_path(root_path, query, page) do
    params = %{"page" => page}
    params = if query == "", do: params, else: Map.put(params, "q", query)
    "#{root_path || "/admin/versions"}?#{URI.encode_query(params)}"
  end

  defp result_summary(total, ""), do: "#{total} deployment#{plural_suffix(total)}"
  defp result_summary(total, _query), do: "#{total} matching deployment#{plural_suffix(total)}"
  defp plural_suffix(1), do: ""
  defp plural_suffix(_count), do: "s"

  defp version_label(row) do
    case row["app_version"] do
      version when is_binary(version) and version not in ["", "unknown"] -> "v#{version}"
      _ -> empty_dash(row["release_id"])
    end
  end

  defp git_messages(row), do: row |> Map.get("git_messages", []) |> List.wrap()

  defp parsed_git_messages(row) do
    Enum.map(git_messages(row), fn message ->
      case Regex.run(~r/^([0-9a-fA-F]{7,40})\s+(.+)$/, message) do
        [_, sha, subject] -> {sha, subject}
        _ -> {nil, message}
      end
    end)
  end

  defp group_by_version(rows) do
    {order, grouped} =
      Enum.reduce(rows, {[], %{}}, fn row, {order, grouped} ->
        version = version_group_key(row)
        order = if Map.has_key?(grouped, version), do: order, else: order ++ [version]
        {order, Map.update(grouped, version, [row], &(&1 ++ [row]))}
      end)

    Enum.map(order, &{&1, Map.fetch!(grouped, &1)})
  end

  defp version_group_key(row), do: row["app_version"] || row["release_id"] || "unknown"
  defp version_group_label("unknown"), do: "Unknown version"
  defp version_group_label(version), do: "v#{version}"

  defp production_comparison([current | history]) do
    if production_environment?(current["environment"]) do
      case Enum.find(history, &(&1["environment"] == current["environment"])) do
        nil -> nil
        previous -> %{current: current, previous: previous}
      end
    end
  end

  defp production_comparison(_rows), do: nil

  defp production_environment?(environment),
    do: environment in ["prod", "production"]

  defp peer_versions_url do
    :acceptance_harness
    |> Application.get_env(:deployment, [])
    |> Keyword.get(:peer_versions_url)
  end

  defp peer_acceptance_url do
    :acceptance_harness
    |> Application.get_env(:deployment, [])
    |> Keyword.get(:peer_acceptance_url)
  end

  defp staging_version_url(_row, nil), do: nil

  defp staging_version_url(row, base_url) do
    query =
      case row["git_sha"] do
        sha when is_binary(sha) and sha not in ["", "unknown"] -> sha
        _ -> row["app_version"]
      end

    if is_binary(query) and query != "" do
      "#{base_url}?#{URI.encode_query(%{"q" => query})}"
    end
  end

  defp acceptance_links(rows, acceptance_path, peer_acceptance_url) do
    rows
    |> local_acceptance_links(acceptance_path)
    |> Enum.map(&put_peer_acceptance_link(&1, peer_acceptance_url))
  end

  defp local_acceptance_links(rows, nil), do: rows

  defp local_acceptance_links(rows, acceptance_path) do
    Enum.map(rows, fn row ->
      case AdminStore.latest_run_for_deployment(row) do
        %{id: run_id} = run ->
          row
          |> Map.put(
            "acceptance_live_url",
            "#{String.trim_trailing(acceptance_path, "/")}/runs/#{URI.encode_www_form(run_id)}"
          )
          |> Map.put("acceptance_static_url", static_report_url(run.source_url))

        nil ->
          row
      end
    end)
  rescue
    _error -> rows
  end

  defp put_peer_acceptance_link(%{"acceptance_live_url" => value} = row, _peer_url)
       when is_binary(value) and value != "",
       do: row

  defp put_peer_acceptance_link(row, peer_url) when is_binary(peer_url) and peer_url != "" do
    deployment = row["pipeline_id"] || row["git_sha"] || row["release_id"]

    if is_binary(deployment) and deployment != "" do
      Map.put(
        row,
        "acceptance_live_url",
        "#{String.trim_trailing(peer_url, "/")}?#{URI.encode_query(%{"deployment" => deployment})}"
      )
    else
      row
    end
  end

  defp put_peer_acceptance_link(row, _peer_url), do: row

  defp static_report_url(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> nil
      String.ends_with?(value, "/index.html") -> value
      true -> String.trim_trailing(value, "/") <> "/index.html"
    end
  end

  defp static_report_url(_value), do: nil
  defp short_sha(value) when is_binary(value), do: value |> String.slice(0, 12) |> empty_dash()
  defp short_sha(_value), do: "-"
  defp empty_dash(value) when value in [nil, ""], do: "-"
  defp empty_dash(value), do: to_string(value)

  defp harness_version do
    case Application.spec(:acceptance_harness, :vsn) do
      nil -> "dev"
      version -> to_string(version)
    end
  end
end

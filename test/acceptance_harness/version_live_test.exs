defmodule AcceptanceHarnessWeb.VersionLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias AcceptanceHarnessWeb.VersionLive

  defmodule DeploymentProvider do
    def current do
      %{
        "app_version" => "1.4.2",
        "release_id" => "v1.4.2-abcdef12-88",
        "environment" => "prod",
        "pipeline_id" => "88",
        "git_sha" => "abcdef1234567890"
      }
    end

    def history, do: []
  end

  test "adds a deployment-specific peer acceptance link when evidence is remote" do
    previous_harness = Application.get_env(:acceptance_harness, :harness)
    previous_deployment = Application.get_env(:acceptance_harness, :deployment)

    on_exit(fn ->
      restore_env(:harness, previous_harness)
      restore_env(:deployment, previous_deployment)
    end)

    Application.put_env(:acceptance_harness, :harness, admin_acceptance_path: nil)

    Application.put_env(:acceptance_harness, :deployment,
      current_provider: {DeploymentProvider, :current, []},
      history_provider: {DeploymentProvider, :history, []},
      peer_acceptance_url: "https://staging.example.org/admin/acceptance/"
    )

    {:ok, socket} = VersionLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{})
    {:noreply, socket} = VersionLive.handle_params(%{}, "/admin/versions", socket)

    assert hd(socket.assigns.rows)["acceptance_live_url"] ==
             "https://staging.example.org/admin/acceptance?deployment=88"
  end

  defp restore_env(key, nil), do: Application.delete_env(:acceptance_harness, key)
  defp restore_env(key, value), do: Application.put_env(:acceptance_harness, key, value)

  test "renders searchable deployment history, pagination, and acceptance link" do
    html =
      VersionLive.render(%{
        rows: [
          %{
            "app_version" => "1.4.2",
            "release_id" => "v1.4.2-abcdef12-88",
            "environment" => "staging",
            "slot" => "green",
            "pipeline_id" => "88",
            "git_sha" => "abcdef1234567890",
            "git_ref" => "main",
            "deployed_at" => "2026-07-21T12:00:00Z",
            "git_messages" => ["Add versions page", "Link acceptance evidence"],
            "acceptance_live_url" => "/admin/acceptance/runs/run-88",
            "acceptance_static_url" =>
              "https://framagit.org/example/app/-/jobs/880/artifacts/file/public/acceptance/index.html",
            "current" => true
          }
        ],
        query: "abcdef",
        page: 2,
        page_size: 10,
        total: 21,
        total_pages: 3,
        root_path: "/admin/versions",
        acceptance_path: "/admin/acceptance",
        version_groups: [
          {"1.4.2",
           [
             %{
               "app_version" => "1.4.2",
               "release_id" => "v1.4.2-abcdef12-88",
               "environment" => "staging",
               "slot" => "green",
               "pipeline_id" => "88",
               "git_sha" => "abcdef1234567890",
               "git_ref" => "main",
               "deployed_at" => "2026-07-21T12:00:00Z",
               "git_messages" => ["abcdef1 Add versions page", "fedcba9 Link acceptance evidence"],
               "acceptance_live_url" => "/admin/acceptance/runs/run-88",
               "acceptance_static_url" =>
                 "https://framagit.org/example/app/-/jobs/880/artifacts/file/public/acceptance/index.html",
               "current" => true
             }
           ]}
        ],
        production_comparison: nil,
        peer_versions_url: nil,
        peer_acceptance_url: nil
      })
      |> rendered_to_string()

    assert html =~ "Deployment versions"
    assert html =~ ~s(id="deployment-version-search")
    assert html =~ ~s(value="abcdef")
    assert html =~ "abcdef123456"
    assert html =~ ~r/<code[^>]*>abcdef1<\/code>\s*<span>Add versions page<\/span>/
    assert html =~ ~r/<code[^>]*>fedcba9<\/code>\s*<span>Link acceptance evidence<\/span>/
    assert html =~ ~s(href="/admin/acceptance")
    assert html =~ ~s(href="/admin/acceptance/runs/run-88")
    assert html =~ "Live acceptance"

    assert html =~
             ~s(href="https://framagit.org/example/app/-/jobs/880/artifacts/file/public/acceptance/index.html")

    assert html =~ "Static report"
    assert html =~ "Page 2 of 3"
    assert html =~ "page=1"
    assert html =~ "page=3"
  end

  test "omits the acceptance link when its path is not configured" do
    html =
      VersionLive.render(%{
        rows: [],
        query: "",
        page: 1,
        page_size: 10,
        total: 0,
        total_pages: 1,
        root_path: "/admin/versions",
        acceptance_path: nil,
        version_groups: [],
        production_comparison: nil,
        peer_versions_url: nil,
        peer_acceptance_url: nil
      })
      |> rendered_to_string()

    refute html =~ "Acceptance evidence"
    assert html =~ "No deployments match"
  end

  test "version cards override the generic two-column card layout" do
    css =
      Path.expand("../../priv/acceptance_harness/admin.css", __DIR__)
      |> File.read!()

    assert css =~
             ~r/\.acceptance-version-card\s*\{[^}]*grid-template-columns:\s*minmax\(0,\s*1fr\)/s

    assert css =~
             ~r/\.acceptance-version-group\s*>\s*h2\s*\{[^}]*font-weight:\s*800/s

    assert css =~
             ~r/\.acceptance-version-heading\s+h3\s*\{[^}]*font-weight:\s*800/s
  end

  test "labels an undeployed version without deployment metadata" do
    row = %{
      "app_version" => "1.4.1",
      "git_sha" => "abcdef1234567890",
      "git_messages" => ["abcdef1 Intermediate version"],
      "committed_at" => "2026-07-20T12:00:00Z",
      "version_only" => true
    }

    html =
      VersionLive.render(%{
        rows: [row],
        query: "",
        page: 1,
        page_size: 10,
        total: 1,
        total_pages: 1,
        root_path: "/admin/versions",
        acceptance_path: nil,
        version_groups: [{"1.4.1", [row]}],
        production_comparison: nil,
        peer_versions_url: nil,
        peer_acceptance_url: nil
      })
      |> rendered_to_string()

    assert html =~ "Version history"
    assert html =~ "Committed"
    assert html =~ "2026-07-20T12:00:00Z"
    refute html =~ "<dt>Release</dt>"
    refute html =~ "<dt>Pipeline</dt>"
    refute html =~ "Deployed at"
  end

  test "compares the running production release and links its staging version" do
    current = %{
      "app_version" => "1.4.2",
      "release_id" => "v1.4.2-abcdef12-88",
      "environment" => "prod",
      "slot" => "blue",
      "pipeline_id" => "88",
      "git_sha" => "abcdef1234567890",
      "git_messages" => ["abcdef1 Current release"],
      "acceptance_live_url" => "https://staging.example.org/admin/acceptance?deployment=88",
      "current" => true
    }

    previous = %{
      "app_version" => "1.4.1",
      "release_id" => "v1.4.1-fedcba98-79",
      "environment" => "prod",
      "slot" => "green",
      "pipeline_id" => "79",
      "git_sha" => "fedcba9876543210",
      "git_messages" => ["fedcba9 Previous release"]
    }

    html =
      VersionLive.render(%{
        rows: [current, previous],
        query: "",
        page: 1,
        page_size: 10,
        total: 2,
        total_pages: 1,
        root_path: "/admin/versions",
        acceptance_path: "/admin/acceptance",
        version_groups: [{"1.4.2", [current]}, {"1.4.1", [previous]}],
        production_comparison: %{current: current, previous: previous},
        peer_versions_url: "https://staging.example.org/admin/versions",
        peer_acceptance_url: "https://staging.example.org/admin/acceptance/"
      })
      |> rendered_to_string()

    assert html =~ "Running production"
    assert html =~ "Previous production"
    assert html =~ "v1.4.2"
    assert html =~ "v1.4.1"

    assert html =~
             ~s(href="https://staging.example.org/admin/versions?q=abcdef1234567890")

    assert html =~
             ~s(href="https://staging.example.org/admin/acceptance?deployment=88")

    assert html =~ "Live acceptance"
    assert html =~ "View this version in staging"
    assert html =~ ~s(data-version-group="1.4.2")
    assert html =~ ~s(data-version-group="1.4.1")
  end
end

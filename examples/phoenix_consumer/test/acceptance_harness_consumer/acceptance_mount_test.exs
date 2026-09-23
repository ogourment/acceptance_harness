defmodule AcceptanceHarnessConsumerWeb.AcceptanceMountTest do
  use AcceptanceHarnessConsumerWeb.ConnCase, async: false

  alias AcceptanceHarness.AdminStore
  alias AcceptanceHarnessConsumer.Repo

  setup do
    AdminStore.install!(repo: Repo)

    Ecto.Adapters.SQL.query!(
      Repo,
      "TRUNCATE acceptance_harness_runs CASCADE",
      []
    )

    AdminStore.import_evidence_data!(evidence(), repo: Repo)
    :ok
  end

  test "mounts the harness routes in a Phoenix consumer", %{conn: conn} do
    conn = conn |> as_superadmin() |> get("/admin/acceptance/latest")

    assert redirected_to(conn) == "/admin/acceptance/runs/consumer-run"

    {:ok, _view, html} = live(as_superadmin(build_conn()), "/admin/acceptance/runs/consumer-run")
    assert html =~ "Harness consumer acceptance run evidence"
    assert html =~ "Participant registers"

    {:ok, timeline, timeline_html} =
      live(
        as_superadmin(build_conn()),
        "/admin/acceptance/runs/consumer-run/scenarios/operator-progress"
      )

    assert has_element?(timeline, ".acceptance-message-timeline")
    assert has_element?(timeline, ".is-telegram")
    assert has_element?(timeline, "[data-channel='telegram']")
    assert timeline_html =~ "Discovering command route"
    assert timeline_html =~ "Inspecting frmwrkog"
    assert timeline_html =~ "Finished in 4s."
    assert length(Regex.scan(~r/data-operation=/, timeline_html)) == 4

    {:ok, acceptance_index, _html} =
      live(as_superadmin(build_conn()), "/admin/acceptance")

    assert has_element?(acceptance_index, "a[href='/admin/versions']", "Deployment versions")
  end

  test "mounts searchable versions beside acceptance for superadmins", %{conn: conn} do
    original_deployment = Application.get_env(:acceptance_harness, :deployment)
    System.put_env("ACCEPTANCE_HARNESS_CONSUMER_GIT_SHA", "abcdef1234567890")
    System.put_env("ACCEPTANCE_HARNESS_CONSUMER_GIT_MESSAGES", "Add shared versions page")

    Application.put_env(:acceptance_harness, :deployment,
      page_size: 2,
      history_provider: fn ->
        [
          %{
            "app_version" => "0.9.0",
            "git_sha" => "deadbeef98765432",
            "git_messages" => ["Repair invitation audit trail"]
          },
          %{
            "app_version" => "0.8.0",
            "git_sha" => "1234567890abcdef",
            "git_messages" => ["Earlier deployment"]
          }
        ]
      end
    )

    on_exit(fn ->
      System.delete_env("ACCEPTANCE_HARNESS_CONSUMER_GIT_SHA")
      System.delete_env("ACCEPTANCE_HARNESS_CONSUMER_GIT_MESSAGES")

      if original_deployment do
        Application.put_env(:acceptance_harness, :deployment, original_deployment)
      else
        Application.delete_env(:acceptance_harness, :deployment)
      end
    end)

    {:ok, view, html} = live(as_superadmin(conn), "/admin/versions")

    assert html =~ "Deployment versions"
    assert html =~ "abcdef123456"
    assert html =~ "Add shared versions page"
    assert html =~ "Page 1 of 2"
    assert has_element?(view, "a[href='/admin/acceptance']", "Acceptance evidence")

    view
    |> form("#deployment-version-search-form", search: %{q: "deadBEEF"})
    |> render_change()

    assert has_element?(view, ".acceptance-version-card", "deadbeef9876")
    refute has_element?(view, ".acceptance-version-card", "abcdef123456")

    view
    |> form("#deployment-version-search-form", search: %{q: "INVITATION audit"})
    |> render_change()

    assert has_element?(view, ".acceptance-version-card", "Repair invitation audit trail")
  end

  test "admin surfaces require the host superadmin pipeline", %{conn: conn} do
    assert conn |> get("/admin/versions") |> response(403) == "superadmin required"
    assert conn |> recycle() |> get("/admin/acceptance") |> response(403) == "superadmin required"

    atdd_session_response =
      conn
      |> recycle()
      |> init_test_session(%{atdd_superadmin: true})
      |> get("/admin/acceptance")

    if System.get_env("ATDD") == "true" do
      assert html_response(atdd_session_response, 200) =~ "Review runs"
    else
      assert response(atdd_session_response, 403) == "superadmin required"
    end
  end

  test "mounts the shared public health endpoint", %{conn: conn} do
    response = conn |> get("/health") |> json_response(200)

    assert response["status"] == "ok"
    assert is_integer(response["age_seconds"])
    assert is_binary(response["age"])
    assert response["pipeline_id"] == "unknown"
  end

  defp evidence do
    %{
      "title" => "Harness consumer acceptance run evidence",
      "run" => %{"id" => "consumer-run"},
      "scenarios" => [
        %{
          "id" => "participant-registers",
          "title" => "Participant registers",
          "status" => "success",
          "steps" => []
        },
        %{
          "id" => "operator-progress",
          "title" => "Operator follows progress",
          "status" => "success",
          "steps" => [
            %{
              "id" => "operator-progress-1",
              "scenario_id" => "operator-progress",
              "position" => 1,
              "sequence" => 2,
              "title" => "Disk status progresses",
              "description" => "Every intermediate state remains reviewable.",
              "screenshot" => %{},
              "metadata" => %{},
              "artifacts" => [],
              "surface" => %{
                "kind" => "message_timeline",
                "channel" => "telegram",
                "frames" => [
                  %{
                    "at_ms" => 0,
                    "operation" => "send",
                    "state" => "accepted",
                    "role" => "assistant",
                    "text" => "Command accepted"
                  },
                  %{
                    "at_ms" => 250,
                    "operation" => "edit",
                    "state" => "discovery",
                    "role" => "assistant",
                    "text" => "Discovering command route"
                  },
                  %{
                    "at_ms" => 1_000,
                    "operation" => "edit",
                    "state" => "inspection",
                    "role" => "assistant",
                    "text" => "Inspecting frmwrkog"
                  },
                  %{
                    "at_ms" => 4_200,
                    "operation" => "edit",
                    "state" => "complete",
                    "role" => "assistant",
                    "text" => "Finished in 4s."
                  }
                ]
              }
            }
          ]
        }
      ]
    }
  end

  defp as_superadmin(conn), do: Plug.Conn.put_req_header(conn, "x-superadmin", "true")
end

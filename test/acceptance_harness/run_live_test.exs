defmodule AcceptanceHarnessWeb.RunLiveTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias AcceptanceHarnessWeb.RunLive

  test "renders clickable scenario thumbnails and redlines the failed step" do
    html =
      RunLive.render(%{
        run: %{
          "id" => "run-1",
          "title" => "Current run",
          "app" => %{"name" => "Ecojeux", "commit" => "1234567890abcdef"},
          "timing" => %{
            "pipeline_age_ms" => 70_000,
            "job_wait_ms" => 12_000,
            "wall_time_ms" => 9_000
          }
        },
        scenarios: [
          %{
            scenario_id: "sessions-facilitator-publishes-desktop",
            title: "Facilitator publishes a session and a participant registers",
            status: "failure",
            work_status: "in_progress",
            devices: ["Desktop"],
            languages: ["Français"],
            users: ["participant"],
            tags: ["registration", "session"],
            duration_ms: 4_200,
            documented_step_ms: 1200,
            undocumented_ms: 3_000,
            change_status: "new",
            failure: %{
              "message" => "Could not publish the session",
              "screenshots" => ["step-2.png"],
              "pending_step" => %{"id" => "step-2", "screenshot_name" => "step-2.png"}
            },
            steps: [
              %{
                id: "step-1",
                title: "Open dashboard",
                sequence: 271_242,
                position: 1,
                screenshot: %{"name" => "step-1.png"}
              },
              %{
                id: "step-2",
                title: "Publish session",
                sequence: 271_243,
                position: 2,
                screenshot: %{"name" => "step-2.png"}
              }
            ]
          }
        ],
        all_scenarios: [],
        filter: %{},
        error: nil,
        root_path: "/admin/acceptance"
      })
      |> rendered_to_string()

    assert html =~ "acceptance-scenario-thumbnails"
    assert html =~ ~s(placeholder="Steps, page text, URLs…")
    refute html =~ ~s(name="status")
    refute html =~ "In progress"
    assert html =~ "Role: participant"
    assert html =~ "Tag: registration"
    assert html =~ "Tag: session"
    assert html =~ "acceptance-change-badge acceptance-scenario-title-change is-new"
    assert html =~ "acceptance-change-icon"
    assert html =~ "aria-label=\"New scenario\""

    assert html =~
             ~r/acceptance-scenario-title-change[\s\S]*Facilitator publishes a session and a participant registers/

    assert html =~
             "href=\"/admin/acceptance/runs/run-1/scenarios/sessions-facilitator-publishes-desktop#step-step-1\""

    assert html =~
             "src=\"/admin/acceptance/screenshots/run-1/step-1.png?variant=thumbnail\""

    assert html =~
             ~r/class="acceptance-step-thumbnail is-failed".*href="\/admin\/acceptance\/runs\/run-1\/scenarios\/sessions-facilitator-publishes-desktop#step-step-2"/s

    assert html =~ ~r/<span class="acceptance-step-thumbnail-index">1<\/span>/
    assert html =~ ~r/<span class="acceptance-step-thumbnail-index">2<\/span>/
    assert html =~ "Failure:</strong> Could not publish the session"
    assert html =~ "acceptance-failure-thumbnail"
    assert html =~ "<dd>1.2 s</dd>"
    assert html =~ "Run breakdown"
    assert html =~ "Pipeline to evidence"
    assert html =~ "1 min 10 s"
    assert html =~ "Timing by ATDD tag / marker"
    assert html =~ "#registration"
    assert html =~ "Rows overlap"

    assert html =~
             "href=\"/admin/acceptance/runs/run-1/scenarios/sessions-facilitator-publishes-desktop#scenario-failure\""

    refute html =~ "271242"
  end

  test "renders ignored and skipped cards with distinct left-edge treatments" do
    scenarios =
      Enum.map(
        [
          {"ignored", "Known solver gap", "Human-like backtracking is incomplete"},
          {"skipped", "Platform-only gesture", "Gesture unavailable in CI"}
        ],
        fn {status, title, reason} ->
          %{
            scenario_id: status,
            title: title,
            status: status,
            status_reason: reason,
            devices: [],
            languages: [],
            users: [],
            tags: [],
            documented_step_ms: 0,
            change_status: nil,
            steps: []
          }
        end
      )

    html =
      RunLive.render(%{
        run: %{
          "id" => "run-1",
          "title" => "Current run",
          "app" => %{"name" => "Punnles", "commit" => "abc"}
        },
        scenarios: scenarios,
        all_scenarios: scenarios,
        filter: %{},
        error: nil,
        root_path: "/admin/acceptance"
      })
      |> rendered_to_string()

    assert html =~
             ~r/acceptance-scenario-card is-ignored[\s\S]*Ignored:[\s\S]*Human-like backtracking is incomplete/

    assert html =~
             ~r/acceptance-scenario-card is-skipped[\s\S]*Skipped:[\s\S]*Gesture unavailable in CI/
  end

  test "renders scenario change counts in run hero and applies change-state styling" do
    html =
      RunLive.render(%{
        run: %{
          "id" => "run-1",
          "title" => "Current run",
          "app" => %{"name" => "Ecojeux", "commit" => "1234567890abcdef"}
        },
        scenarios: [
          %{
            scenario_id: "registers-account",
            title: "Registers a user account",
            status: "success",
            devices: ["Desktop"],
            languages: ["Français"],
            users: ["participant"],
            tags: ["signup"],
            documented_step_ms: 1200,
            change_status: "new",
            steps: []
          },
          %{
            scenario_id: "publishes-session",
            title: "Publishes a new session",
            status: "success",
            devices: ["Desktop"],
            languages: ["English"],
            users: ["participant"],
            tags: ["session"],
            documented_step_ms: 900,
            change_status: "delta",
            steps: []
          }
        ],
        all_scenarios: [],
        filter: %{},
        error: nil,
        root_path: "/admin/acceptance"
      })
      |> rendered_to_string()

    assert html =~
             ~r/<dl class="acceptance-summary-strip">\s*<div class=\"is-new\">\s*<dt>Scenarios<\/dt>/

    assert html =~ "Scenario source changes"
    assert html =~ "<span class=\"acceptance-change-badge is-new\""
    assert html =~ "<span class=\"acceptance-change-badge is-delta\""
    assert html =~ ~r/<dd>2<\/dd>/
    assert html =~ "acceptance-change-badge is-new\" title=\"New\">\n      <svg"

    assert html =~
             "\n    1\n  </span>\n  <span class=\"acceptance-stat-change-item\">\n    <span class=\"acceptance-change-badge is-delta\""
  end

  test "renders compact scenario source-change summaries" do
    html =
      RunLive.render(%{
        run: %{
          "id" => "run-1",
          "title" => "Current run",
          "app" => %{"name" => "Ecojeux", "commit" => "1234567890abcdef"}
        },
        scenarios: [
          %{
            scenario_id: "scenario-new",
            title: "Creates a user account",
            status: "success",
            devices: ["Desktop"],
            languages: ["English"],
            users: ["participant"],
            tags: ["signup"],
            documented_step_ms: 1200,
            change_status: "new",
            steps: []
          },
          %{
            scenario_id: "scenario-renamed",
            title: "Publishes a session to live",
            status: "success",
            devices: ["Desktop"],
            languages: ["English"],
            users: ["participant"],
            tags: ["session"],
            documented_step_ms: 900,
            change_status: "delta",
            previous_title: "Publishes a draft session",
            steps: []
          },
          %{
            scenario_id: "scenario-updated",
            title: "Manages participants",
            status: "success",
            devices: ["Desktop"],
            languages: ["English"],
            users: ["participant"],
            tags: ["participants"],
            documented_step_ms: 1100,
            change_status: "delta",
            previous_title: "Manages participants",
            steps: []
          }
        ],
        all_scenarios: [],
        filter: %{},
        error: nil,
        root_path: "/admin/acceptance"
      })
      |> rendered_to_string()

    assert html =~ "acceptance-change-badge is-new"
    assert html =~ "acceptance-change-badge is-delta"

    assert html =~
             "acceptance_harness v#{to_string(Application.spec(:acceptance_harness, :vsn) || "dev")}"

    assert html =~ "New: Creates a user account"
    refute html =~ "This scenario is newly added."
    assert html =~ "Renamed: Publishes a draft session -&gt; Publishes a session to live"
    refute html =~ "Step title changed:"
    assert html =~ "Updated · No recorded step changed"
    refute html =~ "Adjusted assertions for new copy."
    assert html =~ "acceptance-scenario-change-summary"
  end

  test "renders scenario and step cards with change-aware classes for new and updated items" do
    html =
      RunLive.render(%{
        run: %{
          "id" => "run-1",
          "title" => "Current run",
          "app" => %{"name" => "Ecojeux", "commit" => "1234567890abcdef"}
        },
        scenarios: [
          %{
            scenario_id: "scenario-new",
            title: "New scenario",
            status: "success",
            devices: ["Desktop"],
            languages: ["English"],
            users: ["participant"],
            tags: ["checkout"],
            documented_step_ms: 1200,
            change_status: "new",
            steps: [
              %{
                id: "new-step",
                title: "Open checkout",
                sequence: 10_01,
                screenshot: %{"name" => "new-step.png"},
                change_status: "new"
              }
            ]
          },
          %{
            scenario_id: "scenario-delta",
            title: "Updated scenario",
            status: "success",
            devices: ["Desktop"],
            languages: ["English"],
            users: ["participant"],
            tags: ["account"],
            documented_step_ms: 900,
            change_status: "delta",
            steps: [
              %{
                id: "delta-step",
                title: "Confirm order",
                sequence: 10_02,
                screenshot: %{"name" => "delta-step.png"},
                change_status: "delta"
              }
            ]
          },
          %{
            scenario_id: "scenario-unchanged",
            title: "Unchanged scenario",
            status: "success",
            devices: ["Desktop"],
            languages: ["English"],
            users: ["participant"],
            tags: ["account"],
            documented_step_ms: 950,
            steps: [
              %{
                id: "unchanged-step",
                title: "Review order",
                sequence: 10_03,
                screenshot: %{"name" => "unchanged-step.png"}
              }
            ]
          },
          %{
            scenario_id: "scenario-failed",
            title: "Failed scenario",
            status: "failure",
            devices: ["Desktop"],
            languages: ["English"],
            users: ["participant"],
            tags: ["regression"],
            documented_step_ms: 700,
            change_status: nil,
            failure: %{
              "message" => "Did not succeed",
              "screenshots" => ["failed-step.png"],
              "pending_step" => %{
                "id" => "failed-step",
                "screenshot_name" => "failed-step.png",
                "title" => "Confirm order"
              }
            },
            steps: [
              %{
                id: "failed-step",
                title: "Confirm order",
                sequence: 10_04,
                screenshot: %{"name" => "failed-step.png"},
                change_status: "new"
              }
            ]
          }
        ],
        all_scenarios: [],
        filter: %{},
        error: nil,
        root_path: "/admin/acceptance"
      })
      |> rendered_to_string()

    assert html =~
             ~r/<article[^>]*class=\"acceptance-card acceptance-scenario-card is-new\"[^>]*>[\s\S]*?New scenario/s

    assert html =~
             ~r/<article[^>]*class=\"acceptance-card acceptance-scenario-card is-delta\"[^>]*>[\s\S]*?Updated scenario/s

    refute html =~
             ~r/<article[^>]*class=\"acceptance-card acceptance-scenario-card is-success\"[^>]*>[\s\S]*?Unchanged scenario/s

    assert html =~
             ~r/<article[^>]*class=\"acceptance-card acceptance-scenario-card is-failure\"[^>]*>[\s\S]*?Failed scenario/s

    assert html =~
             ~r/class=\"acceptance-step-thumbnail is-new\"[^>]*href=\"\/admin\/acceptance\/runs\/run-1\/scenarios\/scenario-new#step-new-step\"/s

    assert html =~
             ~r/class=\"acceptance-step-thumbnail is-delta\"[^>]*href=\"\/admin\/acceptance\/runs\/run-1\/scenarios\/scenario-delta#step-delta-step\"/s

    assert html =~
             ~r/class=\"acceptance-step-thumbnail[^>]*href=\"\/admin\/acceptance\/runs\/run-1\/scenarios\/scenario-unchanged#step-unchanged-step\"/s

    refute html =~
             ~r/class=\"acceptance-step-thumbnail[^"]*is-(?:new|delta|failed)\"[^>]*href=\"\/admin\/acceptance\/runs\/run-1\/scenarios\/scenario-unchanged#step-unchanged-step\"/s

    assert html =~
             ~r/class=\"acceptance-step-thumbnail is-failed\"[^>]*href=\"\/admin\/acceptance\/runs\/run-1\/scenarios\/scenario-failed#step-failed-step\"/s
  end

  test "renders complete and changed domain schemas with before and after artifacts" do
    html =
      RunLive.render(%{
        run: %{
          "id" => "run-1",
          "title" => "Current run",
          "app" => %{"name" => "Ecojeux", "commit" => "1234567890abcdef"}
        },
        scenarios: [],
        all_scenarios: [],
        schema_history: %{
          previous_run_id: "run-0",
          overview: %{"path" => "schema/overview.svg"},
          changes: [
            %{
              domain_id: "identity",
              label: "Identity and organisations",
              status: "changed",
              previous: %{
                "label" => "Identity and organisations",
                "path" => "schema/domains/identity.svg",
                "dot_path" => "schema/domains/identity.dot"
              },
              current: %{
                "label" => "Identity and organisations",
                "path" => "schema/domains/identity.svg",
                "dot_path" => "schema/domains/identity.dot"
              }
            },
            %{
              domain_id: "legacy",
              label: "Legacy domain",
              status: "removed",
              previous: %{
                "label" => "Legacy domain",
                "path" => "schema/domains/legacy.svg",
                "dot_path" => "schema/domains/legacy.dot"
              },
              current: nil
            }
          ]
        },
        filter: %{},
        error: nil,
        root_path: "/admin/acceptance"
      })
      |> rendered_to_string()

    assert html =~ ~s(id="domain-schema-changes")
    assert html =~ "Only domains whose generated schema changed are shown."
    assert html =~ "Identity and organisations"

    assert html =~
             ~r/<summary>[\s\S]*?<a[^>]*href="\/admin\/acceptance\/artifacts\/run-1\/schema\/domains\/identity\.svg"[^>]*>[\s\S]*?Identity and organisations[\s\S]*?<\/a>[\s\S]*?<\/summary>/

    assert html =~
             ~r/<summary>[\s\S]*?<a[^>]*href="\/admin\/acceptance\/artifacts\/run-0\/schema\/domains\/legacy\.svg"[^>]*>[\s\S]*?Legacy domain[\s\S]*?<\/a>[\s\S]*?<\/summary>/

    assert html =~ "Before"
    assert html =~ "After"
    assert html =~ ~s(href="/admin/acceptance/artifacts/run-1/schema/overview.svg")
    assert html =~ ~s(src="/admin/acceptance/artifacts/run-0/schema/domains/identity.svg")
    assert html =~ ~s(src="/admin/acceptance/artifacts/run-1/schema/domains/identity.svg")
    assert html =~ ~s(href="/admin/acceptance/artifacts/run-1/schema/domains/identity.dot")
    refute html =~ "Workshops and catalogue"
  end
end

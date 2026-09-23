defmodule AcceptanceHarnessWeb.ScenarioLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias AcceptanceHarnessWeb.ScenarioLive

  test "renders full-width evidence and metadata" do
    html =
      ScenarioLive.render(%{
        run_id: "run-1",
        scenario_id: "checkout",
        scenario: %{
          "status" => "success",
          "scenario_id" => "checkout",
          "title" => "Checkout flow",
          "devices" => ["Desktop"],
          "languages" => ["English"],
          "users" => ["participant"],
          "tags" => ["registration"],
          "duration_ms" => 4_200,
          "documented_step_ms" => 1_200,
          "undocumented_ms" => 3_000
        },
        run: %{"timing" => %{"wall_time_ms" => 9_000, "job_wait_ms" => 12_000}},
        steps: [
          %{
            id: "step-1",
            title: "Open checkout page",
            description: "Select a product and open checkout.",
            screenshot: %{"name" => "checkout.png"},
            metadata: %{
              "current_url" => "https://example.test/checkout",
              "device" => "Desktop",
              "viewport" => "1280x720",
              "theme" => "dark",
              "language" => "en",
              "user" => "alice",
              "click_target" => "button#continue",
              "duration_ms" => 1_200
            }
          }
        ],
        error: nil,
        root_path: "/admin"
      })
      |> rendered_to_string()

    assert html =~ "Checkout flow"
    assert html =~ "acceptance-harness-admin-styles"
    refute html =~ "acceptance-selection-capture"
    refute html =~ "acceptance-harness-selection-script"
    refute html =~ "acceptance-review-layout"
    refute html =~ "acceptance-review-panel"
    refute html =~ "acceptance-scenario-status"
    refute html =~ "acceptance-step-status"
    refute html =~ "Work status"
    assert html =~ "Device: Desktop"
    assert html =~ "Language: English"
    assert html =~ "Role: participant"
    assert html =~ "Tag: registration"
    assert html =~ "Run timing"
    assert html =~ "Evidence job pending"
    assert html =~ "12 s"
    assert html =~ "Scenario timing"
    assert html =~ "4.2 s"
    assert html =~ "3 s"
    assert html =~ "· 1.2 s"
    assert html =~ "Open checkout page"
    assert html =~ "Select a product and open checkout."
    assert html =~ "acceptance-step-heading"

    [_, metadata_html] = Regex.run(~r/<dl class="acceptance-metadata">(.*?)<\/dl>/s, html)

    assert metadata_html =~ "<dt>Device</dt>"
    assert metadata_html =~ "<dd>Desktop</dd>"
    assert metadata_html =~ "<dt>Viewport</dt>"
    assert metadata_html =~ "<dd>1280x720</dd>"
    assert metadata_html =~ "<dt>Theme</dt>"
    assert metadata_html =~ "<dd>dark</dd>"
    assert metadata_html =~ "<dt>Language</dt>"
    assert metadata_html =~ "<dd>en</dd>"
    assert metadata_html =~ "<dt>User</dt>"
    assert metadata_html =~ "<dd>alice</dd>"
    assert metadata_html =~ "<dt>Click target</dt>"
    assert metadata_html =~ "<dd>button#continue</dd>"
    refute metadata_html =~ "<dt>Current URL</dt>"

    assert html =~
             "acceptance_harness v#{to_string(Application.spec(:acceptance_harness, :vsn) || "dev")}"

    assert html =~ "href=\"/admin/screenshots/run-1/checkout.png\""
    assert html =~ "src=\"/admin/screenshots/run-1/checkout.png\""
    assert html =~ "aria-label=\"Screenshot preview\""
    assert html =~ "Clean original"
    assert html =~ "Fit width"
    assert html =~ "Fit window"
    assert html =~ "data-preview-zoom-out"
    assert html =~ "data-preview-zoom-in"
    assert html =~ "data-preview-previous"
    assert html =~ "data-preview-next"
    assert html =~ "data-preview-title=\"Open checkout page\""
    assert html =~ "data-acceptance-step-sequence=\"1\""

    assert html =~ "acceptance-current-url"
    assert html =~ "https://example.test/checkout"
    assert html =~ ~r/acceptance-current-url.*acceptance-screenshot-link/s
  end

  test "renders a terminal surface as visible preformatted evidence" do
    html =
      ScenarioLive.render(%{
        run_id: "run-1",
        scenario_id: "repo-health",
        scenario: %{
          "status" => "success",
          "scenario_id" => "repo-health",
          "title" => "Repository health"
        },
        steps: [
          %{
            id: "step-1",
            title: "Open repository health",
            description: "Shows repository status.",
            screenshot: %{},
            surface: %{
              "kind" => "terminal",
              "text" => "Repository health\n⚠ a55ist  dirty (1 modified)",
              "columns" => 80,
              "rows" => 24
            },
            artifacts: [
              %{
                "type" => "terminal_ansi",
                "path" => "artifacts/repo-health/open.ansi",
                "label" => "Raw terminal output"
              }
            ],
            metadata: %{}
          }
        ],
        error: nil,
        root_path: "/admin/acceptance"
      })
      |> rendered_to_string()

    assert html =~ "acceptance-terminal-screen"
    assert html =~ "<pre"
    assert html =~ "Repository health"
    assert html =~ "⚠ a55ist  dirty (1 modified)"
    assert html =~ "80 × 24"
    assert html =~ "Raw terminal output"
    refute html =~ "No screenshot was captured"
    refute html =~ "Rendered page"
  end

  test "renders a message timeline with ordered timing, operations, and states" do
    html =
      ScenarioLive.render(%{
        run_id: "run-1",
        scenario_id: "health-progress",
        scenario: %{
          "status" => "success",
          "scenario_id" => "health-progress",
          "title" => "Health progress"
        },
        steps: [
          %{
            id: "step-1",
            title: "Health completes",
            description: "Shows every transition.",
            screenshot: %{},
            surface: %{
              "kind" => "message_timeline",
              "channel" => "telegram",
              "frames" => [
                %{
                  "at_ms" => 0,
                  "operation" => "send",
                  "state" => "submitted",
                  "role" => "user",
                  "text" => "/health"
                },
                %{
                  "at_ms" => 420,
                  "operation" => "edit",
                  "state" => "running",
                  "role" => "assistant",
                  "text" => "Checking ogimac\n\nElapsed 1s"
                },
                %{
                  "at_ms" => 5_300,
                  "operation" => "edit",
                  "state" => "complete",
                  "text" => "Health complete\n\nFinished in 5s."
                }
              ]
            },
            artifacts: [],
            metadata: %{}
          }
        ],
        error: nil,
        root_path: "/admin/acceptance"
      })
      |> rendered_to_string()

    assert html =~ "acceptance-message-timeline"
    assert html =~ "is-telegram"
    assert html =~ ~s(data-channel="telegram")
    assert html =~ "is-user"
    assert html =~ "is-assistant"
    assert html =~ "Message timeline · telegram"
    assert html =~ "+420 ms"
    assert html =~ "+5.3s"
    assert html =~ "edit · complete · assistant"
    assert html =~ "Finished in 5s."
    assert length(Regex.scan(~r/data-operation=/, html)) == 3
    refute html =~ "No screenshot was captured"
    refute html =~ "Rendered page"
  end

  test "renders the failure panel for a failed scenario" do
    html =
      ScenarioLive.render(%{
        run_id: "run-1",
        scenario_id: "checkout",
        scenario: %{
          "status" => "failure",
          "scenario_id" => "checkout",
          "title" => "Checkout flow",
          "failure" => %{
            "message" => ~s(Could not find element "[data-gap]" []),
            "code" => ~s{assert_has(conn, "[data-gap]")},
            "location" => "test/checkout_test.exs:106",
            "details" => "full exunit block",
            "screenshots" => ["fail-01.png"],
            "pending_step" => %{
              "title" => "The draft shows the counter",
              "description" => "The new session should be listed."
            }
          }
        },
        steps: [],
        error: nil,
        root_path: "/admin"
      })
      |> rendered_to_string()

    assert html =~ "scenario-failure"
    assert html =~ "Why it failed"
    assert html =~ "acceptance-scenario-failure-preview"
    assert html =~ "Could not find element &quot;[data-gap]&quot; []"
    assert html =~ "test/checkout_test.exs:106"
    assert html =~ "The draft shows the counter"
    assert html =~ "/admin/screenshots/run-1/fail-01.png"
    assert html =~ "Full diagnostic"
  end

  test "renders an unmatched failure as a failed step card" do
    html =
      ScenarioLive.render(%{
        run_id: "run-1",
        scenario_id: "checkout",
        scenario: %{
          "status" => "failure",
          "scenario_id" => "checkout",
          "title" => "Checkout flow",
          "failure" => %{
            "title" => "test checkout flow",
            "message" => ~s(Could not find element "[data-gap]" []),
            "location" => "test/checkout_test.exs:106",
            "screenshots" => ["fail-01.png"],
            "pending_scenario" => %{"id" => "checkout"}
          }
        },
        scenario_change_status: nil,
        scenario_navigation: nil,
        steps: [],
        error: nil,
        root_path: "/admin"
      })
      |> rendered_to_string()

    assert html =~ "Failure before a recorded step"
    assert html =~ "acceptance-step-failure"
    assert html =~ "Could not find element &quot;[data-gap]&quot; []"
    assert html =~ "/admin/screenshots/run-1/fail-01.png"
  end

  test "renders no failure panel for passing scenarios" do
    html =
      ScenarioLive.render(%{
        run_id: "run-1",
        scenario_id: "checkout",
        scenario: %{"status" => "success", "scenario_id" => "checkout", "title" => "Checkout"},
        steps: [],
        error: nil,
        root_path: "/admin"
      })
      |> rendered_to_string()

    refute html =~ "id=\"scenario-failure\""
    refute html =~ "Why it failed"
  end

  test "keeps screenshot and rendered-page evidence navigation" do
    html =
      ScenarioLive.render(%{
        run_id: "run-2",
        scenario_id: "checkout",
        scenario: %{"status" => "success", "scenario_id" => "checkout", "title" => "Checkout"},
        steps: [
          %{
            id: "step-1",
            title: "Open checkout",
            description: "Open it.",
            sequence: 1,
            screenshot: nil,
            metadata: %{"current_url" => "https://example.test/checkout"},
            page_html:
              "<html><head><link rel=\"stylesheet\" href=\"/assets/app.css\"><style>.payment { color: green; }</style></head><body><p class=\"payment\">Pay now</p><script>unsafe()</script></body></html>"
          }
        ],
        error: nil,
        root_path: "/admin"
      })
      |> rendered_to_string()

    assert html =~ "https://example.test/checkout"
    assert html =~ "Screenshot"
    assert html =~ "Rendered page"
    assert html =~ "Pay now"
    assert html =~ "stylesheet"
    assert html =~ "https://example.test"
    refute html =~ "unsafe()"
  end

  test "renders scenario changes as expandable details at the bottom of the title card" do
    html =
      ScenarioLive.render(%{
        run_id: "run-1",
        scenario_id: "checkout",
        scenario_change_status: "delta",
        scenario_change_details: %{
          previous_run_id: "run-0",
          previous_scenario_id: "checkout",
          previous_title: "Old checkout flow"
        },
        scenario: %{
          "status" => "success",
          "scenario_id" => "checkout",
          "title" => "Checkout flow"
        },
        steps: [
          %{
            id: "step-1",
            title: "Open checkout",
            description: "Open the checkout.",
            sequence: 1,
            screenshot: nil,
            metadata: %{},
            change_status: nil
          },
          %{
            id: "step-2",
            title: "Pay",
            description: "Complete payment.",
            sequence: 2,
            screenshot: nil,
            metadata: %{},
            change_status: nil
          }
        ],
        error: nil,
        root_path: "/admin"
      })
      |> rendered_to_string()

    assert html =~ ~s(<details id="scenario-change-details")
    assert html =~ "acceptance-scenario-change-details"
    assert html =~ "What changed?"
    assert html =~ "acceptance-change-icon"
    assert html =~ "Changed scenario"
    assert html =~ "Compared with"
    assert html =~ "run-0"
    assert html =~ "Old checkout flow"
    assert html =~ "Checkout flow"
    assert html =~ "No recorded step changed"
    assert html =~ "2 unchanged steps"
    assert html =~ "scenario setup, assertions, or code outside the captured steps"
    refute html =~ ~r/<span[^>]*acceptance-scenario-title-change/
    refute html =~ ~r/<h1>\s*<span/
  end

  test "scenario change details link directly to changed and new steps" do
    html =
      ScenarioLive.render(%{
        run_id: "run-1",
        scenario_id: "checkout",
        scenario_change_status: "delta",
        scenario_change_details: %{previous_run_id: "run-0"},
        scenario: %{
          "status" => "success",
          "scenario_id" => "checkout",
          "title" => "Checkout flow"
        },
        steps: [
          %{
            id: "step-1",
            title: "Open checkout",
            description: "Open the checkout.",
            sequence: 1,
            screenshot: nil,
            metadata: %{},
            change_status: "delta"
          },
          %{
            id: "step-2",
            title: "Pay",
            description: "Complete payment.",
            sequence: 2,
            screenshot: nil,
            metadata: %{},
            change_status: "new"
          },
          %{
            id: "step-3",
            title: "Receipt",
            description: "Review the receipt.",
            sequence: 3,
            screenshot: nil,
            metadata: %{},
            change_status: nil
          }
        ],
        error: nil,
        root_path: "/admin"
      })
      |> rendered_to_string()

    assert html =~ ~s(href="#step-step-1")
    assert html =~ "Changed step: Open checkout"
    assert html =~ ~s(href="#step-step-2")
    assert html =~ "New step: Pay"
    assert html =~ "1 unchanged step"
    assert html =~ "Checkout flow"
  end

  test "renders source lines and puts step changes before screenshot evidence" do
    html =
      ScenarioLive.render(%{
        run_id: "run-1",
        scenario_id: "checkout",
        scenario_change_status: "delta",
        scenario_change_details: %{previous_run_id: "run-0"},
        scenario_source_diff: %{
          source_file: "test/checkout_atdd_test.exs",
          additions: 1,
          deletions: 1,
          rows: [
            %{kind: :removed, old_line: 10, new_line: nil, text: "old assertion"},
            %{kind: :added, old_line: nil, new_line: 10, text: "new assertion"}
          ]
        },
        scenario: %{
          "status" => "success",
          "scenario_id" => "checkout",
          "title" => "Checkout flow"
        },
        steps: [
          %{
            id: "step-1",
            title: "Open checkout",
            description: "Open the checkout.",
            previous_title: "Open checkout",
            previous_description: "Open the checkout.",
            sequence: 1,
            screenshot: %{"name" => "checkout.png"},
            metadata: %{},
            change_status: "delta"
          }
        ],
        error: nil,
        root_path: "/admin"
      })
      |> rendered_to_string()

    assert html =~ "Scenario source changes"
    assert html =~ "old assertion"
    assert html =~ "new assertion"
    assert html =~ "The recorded title and description are unchanged."

    {change_position, _} = :binary.match(html, ~s(id="step-step-1-change-details"))
    {evidence_position, _} = :binary.match(html, ~s(class="acceptance-evidence-tabs"))
    assert change_position < evidence_position
  end

  test "renders previous and next scenario navigation with cursor" do
    html =
      ScenarioLive.render(%{
        run_id: "run-1",
        scenario_id: "checkout",
        scenario_navigation: %{
          position: 2,
          total: 3,
          previous: "sign-up",
          next: "receipt"
        },
        scenario: %{
          "status" => "success",
          "scenario_id" => "checkout",
          "title" => "Checkout flow"
        },
        steps: [],
        error: nil,
        root_path: "/admin/acceptance"
      })
      |> rendered_to_string()

    assert html =~ "acceptance-breadcrumb"
    assert html =~ "acceptance-scenario-navigation"
    assert html =~ "Run"
    assert html =~ "Scenario"
    assert html =~ "Prev"
    assert html =~ "(2/3)"
    assert html =~ "Next"

    assert html =~
             "href=\"/admin/acceptance/runs/run-1/scenarios/sign-up\""

    assert html =~
             "href=\"/admin/acceptance/runs/run-1/scenarios/receipt\""
  end

  test "renders step cards with change-aware classes for new and updated steps" do
    html =
      ScenarioLive.render(%{
        run_id: "run-1",
        scenario_id: "checkout",
        scenario: %{
          "status" => "success",
          "scenario_id" => "checkout",
          "title" => "Checkout flow"
        },
        steps: [
          %{
            id: "step-new",
            title: "Open checkout",
            description: "Start checkout flow.",
            sequence: 1,
            screenshot: %{"name" => "new-step.png"},
            metadata: %{},
            change_status: "new"
          },
          %{
            id: "step-delta",
            title: "Confirm order",
            description: "Submit order form.",
            previous_title: "Confirm order",
            previous_description: "Submit the old order form.",
            sequence: 2,
            screenshot: %{"name" => "delta-step.png"},
            metadata: %{},
            change_status: "delta"
          },
          %{
            id: "step-unchanged",
            title: "Review confirmation",
            description: "Verify confirmation details.",
            sequence: 3,
            screenshot: %{"name" => "stable-step.png"},
            metadata: %{}
          }
        ],
        error: nil,
        root_path: "/admin/acceptance"
      })
      |> rendered_to_string()

    assert html =~ ~r/id=\"step-step-new\"[^>]*class=\"acceptance-step is-new\"/s
    assert html =~ ~r/id=\"step-step-delta\"[^>]*class=\"acceptance-step is-delta\"/s
    assert html =~ ~r/id=\"step-step-unchanged\"[^>]*class=\"acceptance-step is-unknown\"/s
    refute html =~ "acceptance-step-status"
    assert html =~ ~s(id="step-step-new-change-details")
    assert html =~ "New step"
    assert html =~ "This recorded step is new."
    assert html =~ ~s(id="step-step-delta-change-details")
    assert html =~ "Changed step"
    assert html =~ "The step definition changed."
    assert html =~ "Submit the old order form."
    assert html =~ "Submit order form."
    refute html =~ ~s(id="step-step-unchanged-change-details")
  end

  test "labels schema history as release-level context and links changed steps back to it" do
    html =
      ScenarioLive.render(%{
        run_id: "run-1",
        scenario_id: "checkout",
        scenario: %{
          "status" => "success",
          "scenario_id" => "checkout",
          "title" => "Checkout flow"
        },
        schema_history: %{
          previous_run_id: "run-0",
          overview: nil,
          changes: [
            %{
              domain_id: "registrations",
              label: "Registrations and passport",
              status: "changed"
            }
          ]
        },
        steps: [
          %{
            id: "step-1",
            title: "Register",
            description: "Register for a workshop.",
            sequence: 1,
            screenshot: nil,
            metadata: %{},
            change_status: "delta"
          }
        ],
        error: nil,
        root_path: "/admin"
      })
      |> rendered_to_string()

    assert html =~ ~s(aria-label="Release-level schema changes")
    assert html =~ "This is not automatically attributed to this scenario."
    assert html =~ "Registrations and passport — changed"
    assert html =~ ~s(href="/admin/runs/run-1#schema-domain-registrations")
    assert html =~ "Review release-level schema changes"
    refute html =~ "Identity and organisations"
  end
end

defmodule AcceptanceHarness.EvidenceTest do
  use ExUnit.Case, async: false

  alias AcceptanceHarness.Evidence

  setup do
    original_schema_diagram = Application.get_env(:acceptance_harness, :schema_diagram)
    original_git_sha = System.get_env("ACCEPTANCE_GIT_SHA")
    original_ci_commit_sha = System.get_env("CI_COMMIT_SHA")
    original_ci_pipeline_id = System.get_env("CI_PIPELINE_ID")
    original_ci_pipeline_created_at = System.get_env("CI_PIPELINE_CREATED_AT")
    original_ci_job_created_at = System.get_env("CI_JOB_CREATED_AT")
    original_ci_job_started_at = System.get_env("CI_JOB_STARTED_AT")
    original_atdd_job_wait_seconds = System.get_env("ATDD_JOB_WAIT_SECONDS")

    on_exit(fn ->
      restore_app_env(:schema_diagram, original_schema_diagram)
      restore_env("ACCEPTANCE_GIT_SHA", original_git_sha)
      restore_env("CI_COMMIT_SHA", original_ci_commit_sha)
      restore_env("CI_PIPELINE_ID", original_ci_pipeline_id)
      restore_env("CI_PIPELINE_CREATED_AT", original_ci_pipeline_created_at)
      restore_env("CI_JOB_CREATED_AT", original_ci_job_created_at)
      restore_env("CI_JOB_STARTED_AT", original_ci_job_started_at)
      restore_env("ATDD_JOB_WAIT_SECONDS", original_atdd_job_wait_seconds)
      File.rm_rf!(Path.dirname(Evidence.report_path()))
    end)
  end

  test "includes configured domain schema snapshots in finalized evidence" do
    root =
      Path.join(
        System.tmp_dir!(),
        "acceptance-evidence-schema-#{System.unique_integer([:positive])}"
      )

    output = Path.join(root, "schema")
    domain_output = Path.join(root, "domains")
    domains_file = Path.join(root, "domains.exs")
    File.mkdir_p!(domain_output)
    File.write!(output <> ".dot", "digraph { all; }")
    File.write!(output <> ".svg", "<svg>all</svg>")
    File.write!(Path.join(domain_output, "identity.dot"), "digraph { users; }")
    File.write!(Path.join(domain_output, "identity.svg"), "<svg>identity</svg>")
    File.write!(domains_file, ~s|[%{id: "identity", title: "Identity", tables: ["users"]}]|)

    Application.put_env(:acceptance_harness, :schema_diagram,
      output: output,
      domains_file: domains_file,
      domains_output: domain_output
    )

    Evidence.reset!("ATDD evidence")
    Evidence.finalize!()

    evidence = Evidence.evidence_json_path() |> File.read!() |> Jason.decode!()

    assert Enum.any?(evidence["artifacts"], &(&1["type"] == "schema_overview"))

    assert %{
             "domain_id" => "identity",
             "path" => "schema/domains/identity.svg",
             "dot_path" => "schema/domains/identity.dot"
           } = Enum.find(evidence["artifacts"], &(&1["type"] == "schema_domain"))

    assert File.read!(
             Path.join(Path.dirname(Evidence.evidence_json_path()), "schema/overview.svg")
           ) ==
             "<svg>all</svg>"
  end

  test "records CI commit metadata in the evidence report" do
    System.delete_env("ACCEPTANCE_GIT_SHA")
    System.put_env("CI_COMMIT_SHA", "abc123-ci-sha")
    System.put_env("CI_PIPELINE_ID", "88")

    Evidence.reset!("ATDD evidence")
    Evidence.finalize!()

    assert Evidence.report_path()
           |> File.read!()
           |> String.contains?("Commit: **abc123-ci-sha**")

    assert Evidence.report_path()
           |> File.read!()
           |> String.contains?("App version: **#{Application.spec(:acceptance_harness, :vsn)}**")

    evidence = Evidence.report_json_path() |> File.read!() |> Jason.decode!()
    assert evidence["app"]["pipeline_id"] == "88"
  end

  test "captures scenario source snapshots as evidence artifacts" do
    source_file =
      Path.join(
        System.tmp_dir!(),
        "acceptance-source-#{System.unique_integer([:positive])}.exs"
      )

    File.write!(source_file, "defmodule ExampleScenario do\nend\n")
    on_exit(fn -> File.rm(source_file) end)

    Evidence.reset!("ATDD evidence", [
      %{id: "example", title: "Example", source_file: source_file}
    ])

    Evidence.finalize!()

    evidence = Evidence.evidence_json_path() |> File.read!() |> Jason.decode!()
    [scenario] = evidence["scenarios"]
    snapshot_path = scenario["metadata"]["source_snapshot_path"]

    assert String.starts_with?(snapshot_path, "sources/")

    assert File.read!(Path.join(Path.dirname(Evidence.evidence_json_path()), snapshot_path)) ==
             "defmodule ExampleScenario do\nend\n"

    assert Enum.any?(
             evidence["artifacts"],
             &(&1["type"] == "scenario_source" && &1["path"] == snapshot_path)
           )
  end

  test "captures and fingerprints only the named Elixir test block" do
    source_file =
      Path.join(
        System.tmp_dir!(),
        "acceptance-source-block-#{System.unique_integer([:positive])}.exs"
      )

    File.write!(source_file, """
    defmodule SharedScenarios do
      test "first scenario" do
        assert :first
      end

      test "second scenario" do
        assert :second
      end
    end
    """)

    on_exit(fn -> File.rm(source_file) end)

    Evidence.reset!("ATDD evidence", [
      %{
        id: "second",
        title: "Second scenario",
        source_file: source_file,
        source_test: "second scenario"
      }
    ])

    Evidence.finalize!()

    evidence = Evidence.evidence_json_path() |> File.read!() |> Jason.decode!()
    [scenario] = evidence["scenarios"]
    snapshot_path = scenario["metadata"]["source_snapshot_path"]
    snapshot = File.read!(Path.join(Path.dirname(Evidence.evidence_json_path()), snapshot_path))

    assert snapshot == "  test \"second scenario\" do\n    assert :second\n  end\n"
    refute snapshot =~ "first scenario"

    assert scenario["metadata"]["source_checksum"] ==
             Base.encode16(:crypto.hash(:sha256, snapshot), case: :lower)
  end

  test "rejects a missing named Elixir test block" do
    source_file =
      Path.join(
        System.tmp_dir!(),
        "acceptance-source-missing-#{System.unique_integer([:positive])}.exs"
      )

    File.write!(source_file, "defmodule SharedScenarios do\nend\n")
    on_exit(fn -> File.rm(source_file) end)

    assert_raise ArgumentError, ~r/could not find Elixir test "missing scenario"/, fn ->
      Evidence.reset!("ATDD evidence", [
        %{
          id: "missing",
          title: "Missing scenario",
          source_file: source_file,
          source_test: "missing scenario"
        }
      ])
    end
  end

  test "reports declared ignored and skipped scenarios with their reasons" do
    Evidence.reset!("ATDD evidence", [
      %{
        id: "known-gap",
        title: "Solver recovers from a misplaced piece",
        status: :ignored,
        reason: "The human-like backtracking strategy is incomplete"
      },
      %{
        id: "unsupported-browser",
        title: "Player uses a platform-only gesture",
        status: :skipped,
        reason: "The CI browser does not expose this gesture"
      }
    ])

    Evidence.finalize!()

    report = File.read!(Evidence.report_path())
    evidence = Evidence.report_json_path() |> File.read!() |> Jason.decode!()

    assert report =~ "| 1 | 🟠 |"
    assert report =~ "## 🟠 Scenario: Solver recovers from a misplaced piece"
    assert report =~ "**Ignored:** The human-like backtracking strategy is incomplete"
    assert report =~ "| 2 | ⬛ |"
    assert report =~ "## ⬛ Scenario: Player uses a platform-only gesture"
    assert report =~ "**Skipped:** The CI browser does not expose this gesture"

    assert Enum.map(evidence["scenarios"], &{&1["status"], &1["status_reason"]}) == [
             {"ignored", "The human-like backtracking strategy is incomplete"},
             {"skipped", "The CI browser does not expose this gesture"}
           ]
  end

  test "an ignored scenario executes, records its failure, and does not raise" do
    scenario = %{
      id: "known-gap",
      title: "Known product gap",
      status: :ignored,
      reason: "Implementation is incomplete"
    }

    Evidence.reset!("ATDD evidence", [scenario])
    test_pid = self()

    assert :ignored =
             AcceptanceHarness.ignore(scenario, fn ->
               send(test_pid, :scenario_executed)
               raise "\n\nknown failure\n"
             end)

    assert_received :scenario_executed
    Evidence.finalize!()

    [recorded] =
      Evidence.report_json_path() |> File.read!() |> Jason.decode!() |> Map.fetch!("scenarios")

    assert recorded["status"] == "ignored"
    assert recorded["failure"]["message"] == "known failure"
  end

  test "an ignored failure renders its pending final expectation as not reached" do
    scenario = %{
      id: "known-gap",
      title: "Known product gap",
      status: :ignored,
      reason: "Implementation is incomplete"
    }

    Evidence.reset!("ATDD evidence", [scenario])

    Evidence.record_pending_step(
      "solved.png",
      "Puzzle solved",
      "The puzzle must show `Puzzle solved!`.",
      %{"scenario_id" => "known-gap", "scenario" => "Known product gap", "step" => "4/4"}
    )

    assert :ignored = AcceptanceHarness.ignore(scenario, fn -> raise "not solved" end)
    Evidence.finalize!()

    report = File.read!(Evidence.report_path())
    assert report =~ "### ❌ 4/4 - Puzzle solved (not reached)"
    assert report =~ "The puzzle must show `Puzzle solved!`."

    [recorded] =
      Evidence.report_json_path() |> File.read!() |> Jason.decode!() |> Map.fetch!("scenarios")

    assert [%{"status" => "not_reached", "title" => "Puzzle solved"}] = recorded["steps"]
  end

  test "an ignored scenario that now succeeds is reported as successful" do
    scenario = %{
      id: "recovered-gap",
      title: "Recovered product gap",
      status: :ignored,
      reason: "Previously incomplete"
    }

    Evidence.reset!("ATDD evidence", [scenario])

    assert :ok =
             AcceptanceHarness.ignore(scenario, fn ->
               Evidence.mark_scenario_success!(scenario)
             end)

    Evidence.finalize!()

    [recorded] =
      Evidence.report_json_path() |> File.read!() |> Jason.decode!() |> Map.fetch!("scenarios")

    assert recorded["status"] == "success"
    assert recorded["failure"] == nil
  end

  test "records concise run context and step metadata" do
    System.put_env("CI_PIPELINE_CREATED_AT", "2026-07-04T19:00:00Z")
    System.put_env("CI_JOB_CREATED_AT", "2026-07-04T19:01:00Z")
    System.put_env("CI_JOB_STARTED_AT", "2026-07-04T19:03:05Z")

    Evidence.reset!(
      "ATDD evidence",
      [%{id: "admin-scenario", title: "Admin scenario", roles: ["Admin", "Reviewer"]}],
      %{
        "browser" => "Chromium",
        "platform" => "Linux x86_64",
        "viewport" => "1280x720",
        "touch_points" => "0"
      }
    )

    Evidence.record_step("01.png", "First step", "Description", %{
      "scenario_id" => "admin-scenario",
      "scenario" => "Admin scenario",
      "step" => "1/2",
      "duration_ms" => 42,
      "theme" => "dark",
      "device" => "Desktop",
      "language" => "English",
      "click_target" => "Journeys button",
      "user" => "Admin",
      "current_url" => "http://localhost:4110/admin"
    })

    Evidence.finalize!()
    report = File.read!(Evidence.report_path())

    assert report =~ "## Run Time Breakdown"
    assert report =~ "- ATDD job queue wait: **2m 5s**"

    assert report =~
             "- ATDD report wall time {{help:Elapsed time from starting the evidence collector"

    assert report =~ "- Documented step time: **42 ms** across **1** evidence steps"
    assert report =~ "- Undocumented ATDD work: **"
    assert report =~ "### Scenario Runtime Detail"
    assert report =~ "No scenario runtime samples recorded."

    assert report =~
             "- Full pipeline age at report generation: **"

    assert report =~
             ~r/## Scenario Summary.*## Run Contexts.*## Run Time Breakdown/s

    assert report =~ "- Platform: **Linux x86_64**"
    assert report =~ "- Touch input: **No touch input reported (maxTouchPoints 0)**"
    assert report =~ "| # | Status | Scenario | Devices | Themes | Languages | Duration |"

    assert report =~
             "| 1 | ❌ | [Admin scenario](#-scenario-admin-scenario) | Desktop | dark | English | 42 ms |"

    assert report =~ "### ✅ 1/2 - User: Admin - First step (42 ms)"

    assert report =~
             "Current URL: **http://localhost:4110/admin** - Theme: **dark** - Device: **Desktop** - Language: **English** - Click target: **Journeys button**"

    refute report =~ "User: **-**"
    refute report =~ "User: **Admin**"
    refute report =~ "Viewport: **-**"

    evidence = Evidence.report_json_path() |> File.read!() |> Jason.decode!()

    assert evidence["schema_version"] == "acceptance_harness.evidence.v1"
    assert evidence["title"] == "ATDD evidence"
    assert is_binary(evidence["app"]["commit"])
    assert evidence["app"]["environment"] == "local"
    assert evidence["runner"]["viewport"] == "1280x720"
    assert evidence["timing"]["documented_step_ms"] == 42
    assert evidence["timing"]["finalized"] == true

    assert [
             %{
               "id" => "admin-scenario",
               "status" => "failure",
               "users" => ["Admin", "Reviewer"],
               "steps" => [step]
             }
           ] =
             evidence["scenarios"]

    assert step["title"] == "First step"
    assert step["screenshot"] == %{"name" => "01.png", "path" => "screenshots/01.png"}
    assert step["metadata"]["current_url"] == "http://localhost:4110/admin"
  end

  test "promotes page text/html out of metadata and rolls tags up to the scenario" do
    Evidence.reset!("ATDD evidence", [%{id: "checkout", title: "Checkout"}])

    Evidence.record_step("01.png", "Pay", "Pays the order", %{
      "scenario_id" => "checkout",
      "page_text" => "Votre paiement est confirmé",
      "page_html" => "<main>ok</main>",
      "tags" => "payments, emails"
    })

    Evidence.record_step("02.png", "Done", "Confirmation", %{
      "scenario_id" => "checkout",
      "tags" => ["payments"]
    })

    refute File.exists?(Evidence.evidence_json_path())
    Evidence.finalize!()

    report = Evidence.evidence_json_path() |> File.read!() |> Jason.decode!()
    [scenario] = report["scenarios"]

    assert scenario["tags"] == ["payments", "emails"]

    [pay_step, done_step] = scenario["steps"]

    assert pay_step["page"] == %{
             "text" => "Votre paiement est confirmé",
             "html" => "<main>ok</main>"
           }

    refute Map.has_key?(pay_step["metadata"], "page_text")
    refute Map.has_key?(pay_step["metadata"], "page_html")
    refute Map.has_key?(pay_step["metadata"], "tags")
    assert pay_step["tags"] == ["payments", "emails"]
    assert done_step["tags"] == ["payments"]

    # The captured page must never leak into the human report.
    refute File.read!(Evidence.report_path()) =~ "paiement est confirmé"
  end

  test "records terminal surfaces and generic artifacts without changing evidence v1" do
    Evidence.reset!("ATDD evidence", [%{id: "repo-health", title: "Repository health"}])

    Evidence.record_step("", "Open repository health", "Shows repository status.", %{
      "scenario_id" => "repo-health",
      "surface" => %{
        "kind" => "terminal",
        "text" => "Repository health\n⚠ a55ist  dirty (1 modified)",
        "columns" => 80,
        "rows" => 24
      },
      "artifacts" => [
        %{
          "type" => "terminal_ansi",
          "path" => "artifacts/repo-health/open.ansi",
          "label" => "Raw terminal output"
        },
        %{
          "type" => "terminal_text",
          "path" => "artifacts/repo-health/normalized screen.txt",
          "label" => "Normalized ](https://example.test) [ screen"
        }
      ]
    })

    Evidence.mark_scenario_success!(%{id: "repo-health", title: "Repository health"})
    Evidence.finalize!()

    evidence = Evidence.evidence_json_path() |> File.read!() |> Jason.decode!()
    [scenario] = evidence["scenarios"]
    [step] = scenario["steps"]

    assert evidence["schema_version"] == "acceptance_harness.evidence.v1"
    assert step["screenshot"] == %{"name" => "", "path" => "screenshots"}

    assert step["surface"] == %{
             "kind" => "terminal",
             "text" => "Repository health\n⚠ a55ist  dirty (1 modified)",
             "columns" => 80,
             "rows" => 24
           }

    assert length(step["artifacts"]) == 2

    refute Map.has_key?(step["metadata"], "surface")
    refute Map.has_key?(step["metadata"], "artifacts")

    report = File.read!(Evidence.report_path())
    assert report =~ "⚠ a55ist  dirty (1 modified)"
    assert report =~ "[Normalized  (https://example.test)   screen]"
    assert report =~ "(artifacts/repo-health/normalized%20screen.txt)"
    refute report =~ "](https://example.test)"
  end

  test "records message timelines as framework-neutral evidence" do
    Evidence.reset!("ATDD evidence", [%{id: "health-progress", title: "Health progress"}])

    Evidence.record_step("", "Health completes", "Shows every user-visible transition.", %{
      "scenario_id" => "health-progress",
      "surface" => %{
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
            "text" => "Checking `ogimac`\n\nElapsed 1s"
          },
          %{
            "at_ms" => 5_300,
            "operation" => "edit",
            "state" => "complete",
            "text" => "Health complete\n\nFinished in `5s`."
          }
        ]
      }
    })

    Evidence.mark_scenario_success!(%{id: "health-progress", title: "Health progress"})
    Evidence.finalize!()

    evidence = Evidence.evidence_json_path() |> File.read!() |> Jason.decode!()
    [step] = get_in(evidence, ["scenarios", Access.at(0), "steps"])

    assert step["surface"]["kind"] == "message_timeline"
    assert step["surface"]["channel"] == "telegram"

    assert Enum.map(step["surface"]["frames"], & &1["state"]) == [
             "submitted",
             "running",
             "complete"
           ]

    report = File.read!(Evidence.report_path())
    assert report =~ "Message timeline — telegram"
    assert report =~ "+420 ms · edit · running"
    assert report =~ "+420 ms · edit · running · assistant"
    assert report =~ "Finished in `5s`."
    refute report =~ "screenshots/"
  end

  test "records legacy scenario ids as durable identity metadata" do
    Evidence.reset!("ATDD evidence", [
      %{
        id: "participants-01-checkout",
        title: "Participant checks out",
        legacy_ids: [" checkout ", "checkout", ""]
      }
    ])

    Evidence.finalize!()
    evidence = Evidence.evidence_json_path() |> File.read!() |> Jason.decode!()
    [scenario] = evidence["scenarios"]

    assert scenario["metadata"]["legacy_ids"] == ["checkout"]
  end

  test "orders scenario sections by declared scenario order and records success" do
    Evidence.reset!(
      "ATDD evidence",
      [
        %{id: "first", title: "First scenario"},
        %{id: "second", title: "Second scenario"}
      ],
      %{}
    )

    Evidence.record_step("02.png", "Second step", "Description", %{
      "scenario_id" => "second",
      "scenario" => "Second scenario",
      "device" => "Phone",
      "theme" => "light",
      "language" => "French",
      "duration_ms" => 5
    })

    Evidence.record_step("01.png", "First step", "Description", %{
      "scenario_id" => "first",
      "scenario" => "First scenario",
      "device" => "Desktop",
      "theme" => "dark",
      "language" => "English",
      "duration_ms" => 7
    })

    Evidence.mark_scenario_success!(%{id: "first", title: "First scenario"})
    Evidence.finalize!()

    report = File.read!(Evidence.report_path())

    assert report =~ "- Documented step time: **12 ms** across **2** evidence steps"

    assert report =~
             "| 1 | ✅ | [First scenario](#-scenario-first-scenario) | Desktop | dark | English | 7 ms |"

    assert report =~
             "| 2 | ❌ | [Second scenario](#-scenario-second-scenario) | Phone | light | French | 5 ms |"

    assert String.split(report, "## ✅ Scenario: First scenario") |> length() == 2

    assert report =~
             ~r/## ✅ Scenario: First scenario.*## ❌ Scenario: Second scenario/s
  end

  test "formats long report durations for scanning" do
    Evidence.reset!("ATDD evidence", [%{id: "scenario", title: "Scenario"}], %{})

    Evidence.record_step("01.png", "Long step", "Description", %{
      "scenario_id" => "scenario",
      "duration_ms" => 117_377
    })

    Evidence.mark_scenario_success!(%{id: "scenario", title: "Scenario"})
    Evidence.finalize!()
    report = File.read!(Evidence.report_path())

    assert report =~ "- Documented step time: **1m 57s** across **1** evidence steps"
    assert report =~ "### ✅ Long step (1m 57s)"
  end

  test "rounds second-level report durations" do
    Evidence.reset!("ATDD evidence", [%{id: "scenario", title: "Scenario"}], %{})

    Evidence.record_step("01.png", "Step", "Description", %{
      "scenario_id" => "scenario",
      "duration_ms" => 5_600
    })

    Evidence.mark_scenario_success!(%{id: "scenario", title: "Scenario"})
    Evidence.finalize!()
    report = File.read!(Evidence.report_path())

    assert report =~ "- Documented step time: **6s** across **1** evidence steps"
    assert report =~ "### ✅ Step (6s)"
  end

  test "uses exported ATDD queue wait when GitLab timestamps are unavailable" do
    System.delete_env("CI_JOB_CREATED_AT")
    System.delete_env("CI_JOB_STARTED_AT")
    System.put_env("ATDD_JOB_WAIT_SECONDS", "127")

    Evidence.reset!("ATDD evidence", [], %{})
    Evidence.finalize!()

    assert File.read!(Evidence.report_path()) =~ "- ATDD job queue wait: **2m 7s**"
  end

  test "records scenario runtime detail separately from captured screenshot steps" do
    Evidence.reset!("ATDD evidence", [%{id: "scenario", title: "Scenario"}], %{})

    Evidence.record_step("01.png", "Step", "Description", %{
      "scenario_id" => "scenario",
      "duration_ms" => 1_500
    })

    Evidence.record_scenario_runtime(%{id: "scenario", title: "Scenario"}, 4_000)
    Evidence.finalize!()

    report = File.read!(Evidence.report_path())

    assert report =~ "| Scenario | Elapsed | Documented steps | Undocumented |"
    assert report =~ "| Scenario | 4s | 2s | 3s |"
  end

  test "records current scenario runtime from the shared test boundary" do
    Evidence.reset!("ATDD evidence", [%{id: "scenario", title: "Scenario"}], %{})
    Evidence.start_scenario_runtime!()
    Evidence.record_current_scenario_runtime(%{id: "scenario", title: "Scenario"})
    Evidence.finalize!()

    evidence =
      Evidence.report_path()
      |> Path.dirname()
      |> Path.join("evidence.json")
      |> File.read!()
      |> Jason.decode!()

    assert [%{"duration_ms" => duration_ms}] = evidence["scenarios"]
    assert is_integer(duration_ms)
    assert duration_ms >= 0
  end

  test "renders a multi-user scenario overview when steps have user labels" do
    Evidence.reset!("ATDD evidence", [%{id: "scenario", title: "Scenario"}], %{})

    Evidence.record_step("admin.png", "Admin advances", "Description", %{
      "scenario_id" => "scenario",
      "step" => "1/2",
      "user" => "Admin",
      "device" => "Desktop",
      "viewport" => "1280x720",
      "theme" => "dark",
      "language" => "English",
      "duration_ms" => 10
    })

    Evidence.record_step("alice.png", "Alice answers", "Description", %{
      "scenario_id" => "scenario",
      "step" => "1/2",
      "user" => "Alice",
      "device" => "Phone",
      "viewport" => "390x844",
      "theme" => "light",
      "language" => "French",
      "duration_ms" => 12
    })

    Evidence.mark_scenario_success!(%{id: "scenario", title: "Scenario"})
    Evidence.finalize!()
    report = File.read!(Evidence.report_path())

    assert report =~ "### Multi-user view"
    assert report =~ "| Step | Admin | Alice |"

    assert report =~
             "| View | Desktop · 1280x720 · dark · English | Phone · 390x844 · light · French |"

    assert report =~
             "| 1/2 | ![Admin advances](screenshots/admin.png) | ![Alice answers](screenshots/alice.png) |"
  end

  test "stores pending step context and clears it when the step is captured" do
    Evidence.reset!("ATDD evidence", [%{id: "scenario", title: "Scenario"}], %{})

    metadata = %{
      "scenario_id" => "scenario",
      "scenario" => "Scenario",
      "step" => "2/3",
      "user" => "Alice",
      "device" => "Phone",
      "viewport" => "390x844",
      "theme" => "light",
      "language" => "French",
      "current_url" => "https://staging.agile-u.com/journeys/example"
    }

    Evidence.record_pending_step(
      "alice.png",
      "Alice answers",
      "Alice selects descriptors.",
      metadata
    )

    pending_path =
      Evidence.report_path()
      |> Path.dirname()
      |> Path.join("pending_steps.json")

    assert pending_path
           |> File.read!()
           |> Jason.decode!()
           |> List.first()
           |> get_in(["metadata", "viewport"]) == "390x844"

    Evidence.record_step("alice.png", "Alice answers", "Alice selects descriptors.", metadata)

    assert Jason.decode!(File.read!(pending_path)) == []
  end

  test "stores pending scenario context and clears it when the scenario succeeds" do
    scenario = %{id: "scenario", title: "Scenario"}
    Evidence.reset!("ATDD evidence", [scenario], %{})

    metadata = %{
      "scenario_id" => "scenario",
      "scenario" => "Scenario",
      "current_url" => "https://staging.agile-u.com/journeys/example",
      "theme" => "dark"
    }

    Evidence.record_pending_scenario(scenario, metadata)

    pending_path =
      Evidence.report_path()
      |> Path.dirname()
      |> Path.join("pending_scenarios.json")

    assert pending_path
           |> File.read!()
           |> Jason.decode!()
           |> List.first()
           |> get_in(["metadata", "current_url"]) ==
             "https://staging.agile-u.com/journeys/example"

    Evidence.mark_scenario_success!(scenario)

    assert Jason.decode!(File.read!(pending_path)) == []
  end

  test "marks finalized scenarios with no captured steps as failed" do
    Evidence.reset!(
      "ATDD evidence",
      [%{id: "not-captured", title: "Not captured scenario"}],
      %{}
    )

    Evidence.finalize!()
    report = File.read!(Evidence.report_path())

    assert report =~
             "| 1 | ❌ | [Not captured scenario](#-scenario-not-captured-scenario) | - | - | - | 0 ms |"

    assert report =~ "## ❌ Scenario: Not captured scenario"
    assert report =~ "No evidence steps were captured for this scenario."
  end

  @tag timeout: 10_000
  test "evidence transitions tolerate report writes longer than GenServer's default timeout" do
    Evidence.reset!("ATDD evidence", [%{id: "slow", title: "Slow evidence"}], %{})
    agent = Process.whereis(AcceptanceHarness.Evidence.Agent)
    :ok = :sys.suspend(agent)

    task =
      Task.async(fn ->
        Evidence.mark_scenario_success!(%{id: "slow", title: "Slow evidence"})
      end)

    try do
      Process.sleep(5_100)
      assert Process.alive?(task.pid)
    after
      :ok = :sys.resume(agent)
    end

    assert :ok = Task.await(task, 1_000)
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp restore_app_env(key, nil), do: Application.delete_env(:acceptance_harness, key)
  defp restore_app_env(key, value), do: Application.put_env(:acceptance_harness, key, value)
end

defmodule AcceptanceHarnessConsumerWeb.ReviewerTimingATDDTest do
  use AcceptanceHarness.Playwright.ATDDCase, async: false
  alias AcceptanceHarness.{AdminStore, Evidence, JobTiming}
  alias AcceptanceHarnessConsumer.Repo

  @scenario %{
    id: "reviewer-inspects-job-pending-time",
    title: "Reviewer diagnoses evidence job pending time",
    metadata: %{role: "application owner/reviewer", tags: ["acceptance", "timing"]}
  }

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    AdminStore.install!(repo: Repo)

    root =
      AcceptanceHarnessConsumer.ReviewEvidence.start_run!("Evidence timing acceptance", @scenario)

    {:ok, root: root}
  end

  @tag :atdd
  test "reviewer follows timing from imported run to scenario and persisted reload", %{conn: conn} do
    timing =
      JobTiming.from_job(%{
        "id" => 42,
        "created_at" => "2026-09-20T12:00:00.000Z",
        "started_at" => "2026-09-20T12:02:05.250Z",
        "queued_duration" => 1.125
      })

    id = "timing-#{System.unique_integer([:positive])}"

    data = %{
      "title" => "Job timing investigation",
      "run" => %{"id" => id},
      "timing" => timing,
      "app" => %{"name" => "Timing fixture"},
      "scenarios" => [
        %{
          "id" => "review-job",
          "title" => "Review this job",
          "status" => "success",
          "steps" => [%{"id" => "inspect", "title" => "Inspect timing", "sequence" => 1}]
        }
      ]
    }

    data = Jason.decode!(Jason.encode!(data))
    AdminStore.import_evidence_data!(data, repo: Repo)

    conn =
      conn
      |> visit("/test/atdd/login")
      |> assert_has("a", text: "Continue as isolated reviewer")
      |> capture("01-entry", "Enter isolated reviewer", "Open the visible reviewer sign-in link")
      |> click_link("Continue as isolated reviewer")
      |> assert_has("a", text: "Job timing investigation")
      |> capture("02-runs", "Find the imported evidence run", "Continue as isolated reviewer")
      |> click_link("Job timing investigation")
      |> assert_has("dd", text: "2 min 5 s")
      |> assert_has("dd", text: "1.1 s")
      |> capture(
        "03-run",
        "Read job pending separately from runner queue",
        "Open Job timing investigation"
      )
      |> click_link("Review this job")
      |> assert_has("#acceptance-run-timing dd", text: "2 min 5 s")
      |> capture("04-scenario", "Retain run timing inside the scenario", "Open Review this job")

    AdminStore.import_evidence_data!(data, repo: Repo)
    assert AdminStore.get_run!(id, repo: Repo)["timing"]["job_wait_ms"] == 125_250

    conn
    |> click_link("Run")
    |> assert_has("dd", text: "2 min 5 s")
    |> capture(
      "05-retained",
      "Keep precise timing after reimport",
      "Return to Run after reimport"
    )

    Evidence.mark_scenario_success!(@scenario)
    Evidence.finalize!()
  end

  defp capture(conn, id, title, action),
    do: AcceptanceHarnessConsumer.ReviewEvidence.capture(conn, @scenario, id, title, action)
end

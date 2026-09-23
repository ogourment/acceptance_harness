defmodule AcceptanceHarnessConsumerWeb.ReviewerAutomationATDDTest do
  use AcceptanceHarness.Playwright.ATDDCase, async: false
  alias AcceptanceHarness.{AdminStore, Evidence, ReviewStore}
  alias AcceptanceHarnessConsumer.{Repo, ReviewEvidence}

  @scenario %{
    id: "reviewer-separates-automation-and-tracking-failures",
    title: "Owner distinguishes automation and incomplete tracking",
    metadata: %{role: "application owner/reviewer", tags: ["acceptance", "review-activity"]}
  }
  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    AdminStore.install!(repo: Repo)
    ReviewEvidence.start_run!("Review measurement integrity", @scenario)
    :ok
  end

  @tag :atdd
  test "automated navigation remains separate and a collector failure preserves evidence", %{
    conn: conn
  } do
    id = "automated-#{System.unique_integer([:positive])}"
    project = "Automation fixture #{id}"

    AdminStore.import_evidence_data!(
      %{
        "title" => "Automation fixture",
        "run" => %{"id" => id},
        "app" => %{"name" => project},
        "scenarios" => [
          %{
            "id" => "journey",
            "title" => "Inspect automation",
            "status" => "success",
            "steps" => []
          }
        ]
      },
      repo: Repo
    )

    conn =
      conn
      |> visit("/test/atdd/login")
      |> assert_has("a", text: "Continue as isolated reviewer")
      |> capture(
        "01-entry",
        "Enter review as declared browser automation",
        "Open isolated sign-in"
      )
      |> click_link("Continue as isolated reviewer")
      |> assert_has("a", text: "Automation fixture")
      |> capture("02-list", "Choose the evidence run", "Continue as isolated reviewer")
      |> click_link("Automation fixture")
      |> assert_has("[data-review-count]", text: "1 automated", timeout: 10_000)
      |> assert_has("[data-review-count]", text: "0 cumulative reads")
      |> capture(
        "03-separated",
        "Keep automated activity out of human totals",
        "Open Automation fixture"
      )

    receipts = ReviewStore.export(project, repo: Repo)
    assert receipts != []
    assert Enum.all?(receipts, &(&1["source"] == "automated"))
    Ecto.Adapters.SQL.query!(Repo, "DROP TABLE acceptance_harness_review_receipts", [])

    conn
    |> click_link("Inspect automation")
    |> assert_has("h1", text: "Inspect automation")
    |> assert_has("[data-review-count]", text: "Review tracking incomplete", timeout: 10_000)
    |> capture(
      "04-incomplete",
      "Keep evidence usable during collector failure",
      "Open Inspect automation while the isolated collector is unavailable"
    )

    Evidence.mark_scenario_success!(@scenario)
    Evidence.finalize!()
  end

  defp capture(conn, id, title, action),
    do: ReviewEvidence.capture(conn, @scenario, id, title, action)
end

defmodule AcceptanceHarnessConsumerWeb.ReviewerLightboxReadsATDDTest do
  use AcceptanceHarness.Playwright.ATDDCase, async: false
  alias AcceptanceHarness.{AdminStore, Evidence, ReviewStore, ReviewTarget}
  alias AcceptanceHarnessConsumer.{Repo, ReviewEvidence}

  @scenario %{
    id: "reviewer-counts-lightbox-evidence",
    title: "Reviewer counts only the evidence currently shown in the lightbox",
    metadata: %{role: "application owner/reviewer", tags: ["acceptance", "review-activity"]}
  }

  setup %{conn: %{context_id: context_id}} do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    AdminStore.install!(repo: Repo)

    PlaywrightEx.BrowserContext.add_init_script(context_id,
      source: "Object.defineProperty(navigator, 'webdriver', {get: () => false})",
      timeout: 10_000
    )

    root = ReviewEvidence.start_run!("Lightbox readership acceptance", @scenario)
    {:ok, root: root}
  end

  @tag :atdd
  test "advancing the lightbox counts each visible step, even when steps share one image", %{
    conn: conn,
    root: root
  } do
    run_id = "lightbox-#{System.unique_integer([:positive])}"
    project = "Lightbox fixture #{run_id}"

    conn =
      conn
      |> visit("/test/atdd/login")
      |> capture("01-entry", "Enter isolated review", "Open the known sign-in link")

    AdminStore.import_evidence_data!(
      %{
        "run" => %{"id" => run_id},
        "title" => "Lightbox readership",
        "app" => %{"name" => project},
        "scenarios" => [
          %{
            "id" => "inspect",
            "title" => "Inspect both observations",
            "status" => "success",
            "steps" =>
              for(
                {id, title, number} <- [
                  {"first", "First observation", 1},
                  {"second", "Second observation", 2}
                ],
                do: %{
                  "id" => id,
                  "scenario_id" => "inspect",
                  "sequence" => number,
                  "title" => title,
                  "description" => "Inspect the captured entry screen",
                  "metadata" => %{"review_id" => id},
                  "screenshot" => %{"name" => "01-entry.png"}
                }
              )
          }
        ]
      }, repo: Repo, source_dir: root)

    conn =
      conn
      |> click_link("Continue as isolated reviewer")
      |> assert_has("a", text: "Lightbox readership")
      |> capture("02-list", "Choose the imported run", "Continue as isolated reviewer")
      |> click_link("Lightbox readership")
      |> assert_has("a", text: "Inspect both observations")
      |> capture("03-run", "Choose the scenario", "Open Lightbox readership")
      |> click_link("Inspect both observations")
      |> click("#step-first a.acceptance-screenshot-link")
      |> assert_has("[data-preview-title]", text: "First observation")
      |> assert_has("#step-first > [data-review-count]",
        text: "1 cumulative reads",
        timeout: 10_000
      )
      |> capture(
        "04-first-preview",
        "Count only the first previewed observation",
        "Open the First observation screenshot"
      )

    second = ReviewTarget.resolve(run_id, "inspect", "second")
    assert ReviewStore.summary(project, second.target, second.revision, repo: Repo).reads == 0

    conn =
      conn
      |> click("[data-preview-next]")
      |> assert_has("[data-preview-title]", text: "Second observation")
      |> assert_has("#step-second > [data-review-count]",
        text: "1 cumulative reads",
        timeout: 10_000
      )
      |> capture(
        "05-next-preview",
        "Count the second observation after navigation",
        "Choose Next inside the lightbox"
      )
      |> click("[data-preview-close]")
      |> assert_has("#step-first > [data-review-count]", text: "1 cumulative reads")
      |> assert_has("#step-second > [data-review-count]", text: "1 cumulative reads")
      |> capture(
        "06-counts",
        "Retain both counts after closing",
        "Close the lightbox and inspect the page counts"
      )

    assert ReviewStore.summary(project, second.target, second.revision, repo: Repo).reads == 1

    conn
    |> reload_page()
    |> assert_has("#step-second > [data-review-count]",
      text: "1 cumulative reads",
      timeout: 10_000
    )

    Evidence.mark_scenario_success!(@scenario)
    Evidence.finalize!()
  end

  defp capture(conn, id, title, action),
    do: ReviewEvidence.capture(conn, @scenario, id, title, action)
end

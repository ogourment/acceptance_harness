defmodule AcceptanceHarnessConsumerWeb.ReviewerUsageATDDTest do
  use AcceptanceHarness.Playwright.ATDDCase, async: false
  alias AcceptanceHarness.{AdminStore, Evidence, ReviewStore, ReviewTarget}
  alias AcceptanceHarnessConsumer.{Repo, ReviewEvidence}

  @scenario %{
    id: "reviewer-counts-visible-evidence",
    title: "Owner follows cumulative human review activity",
    metadata: %{role: "application owner/reviewer", tags: ["acceptance", "review-activity"]}
  }

  setup %{conn: %{context_id: context_id}} do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    AdminStore.install!(repo: Repo)
    old = Application.get_env(:acceptance_harness, :harness)

    Application.put_env(
      :acceptance_harness,
      :harness,
      Keyword.put(old, :review_environment, "dev")
    )

    on_exit(fn -> Application.put_env(:acceptance_harness, :harness, old) end)
    # Simulate the human browser classification only inside this isolated context.
    # Every receipt still comes from actual UI navigation and viewport observation.
    PlaywrightEx.BrowserContext.add_init_script(context_id,
      source: "Object.defineProperty(navigator, 'webdriver', {get: () => false})",
      timeout: 10_000
    )

    ReviewEvidence.start_run!("Review readership acceptance", @scenario)
    :ok
  end

  @tag :atdd
  test "owner counts visible evidence and carries dev reviews to staging without duplication", %{
    conn: conn
  } do
    run_id = "read-#{System.unique_integer([:positive])}"
    project = "Review fixture #{run_id}"

    data = %{
      "title" => "Readership fixture",
      "run" => %{"id" => run_id},
      "app" => %{"name" => project, "commit" => "same-release"},
      "scenarios" => [
        %{
          "id" => "journey",
          "title" => "Inspect review history",
          "status" => "success",
          "steps" => [
            %{
              "id" => "visible",
              "scenario_id" => "journey",
              "title" => "Visible outcome",
              "description" => "A reviewed result",
              "sequence" => 1
            },
            %{
              "id" => "unseen",
              "scenario_id" => "journey",
              "title" => "Unseen outcome",
              "sequence" => 2
            }
          ]
        }
      ]
    }

    AdminStore.import_evidence_data!(data, repo: Repo)

    conn =
      conn
      |> visit("/test/atdd/login")
      |> assert_has("a", text: "Continue as isolated reviewer")
      |> capture("01-entry", "Enter as reviewer", "Open isolated sign-in")
      |> click_link("Continue as isolated reviewer")
      |> assert_has("a", text: "Readership fixture")
      |> capture("02-list", "Select one run", "Continue as isolated reviewer")
      |> click_link("Readership fixture")
      |> assert_has("[data-review-count]", text: "1 cumulative reads", timeout: 10_000)
      |> capture("03-run", "Count the visible run once", "Open Readership fixture")
      |> click_link("Inspect review history")
      |> assert_has("[data-review-target] > [data-review-count]",
        text: "1 cumulative reads",
        timeout: 10_000
      )
      |> capture("04-scenario", "Count the opened scenario", "Open Inspect review history")

    # Scroll through real evidence; visibility, not a synthetic tracking request,
    # causes the step receipt.
    conn =
      conn
      |> evaluate(
        "() => document.querySelector('#step-visible').scrollIntoView()",
        [is_function: true],
        fn _ -> :ok end
      )
      |> assert_has("#step-visible > [data-review-count]",
        text: "1 cumulative reads",
        timeout: 10_000
      )
      |> capture("05-step", "Record the visible step", "Scroll to Visible outcome")

    receipts = ReviewStore.export(project, repo: Repo)

    assert Enum.any?(
             receipts,
             &(&1["target"] == "scenario/journey" and &1["environment"] == "dev")
           )

    assert {:ok, 0} = ReviewStore.import!(project, receipts, repo: Repo)
    target = ReviewTarget.resolve(run_id, "journey")
    assert ReviewStore.summary(project, target.target, target.revision, repo: Repo).reads == 1
    config = Application.get_env(:acceptance_harness, :harness)

    Application.put_env(
      :acceptance_harness,
      :harness,
      Keyword.put(config, :review_environment, "staging")
    )

    conn =
      conn
      |> click_link("Run")
      |> click_link("Inspect review history")
      |> assert_has("[data-review-target] > [data-review-count]", text: "dev 1", timeout: 10_000)
      |> capture(
        "06-promoted",
        "Retain dev-origin review on staging",
        "Return through Run and reopen the scenario"
      )

    assert ReviewStore.summary(project, target.target, target.revision, repo: Repo).reads == 1

    conn =
      conn
      |> reload_page()
      |> assert_has("[data-review-target] > [data-review-count]",
        text: "1 cumulative reads",
        timeout: 10_000
      )
      |> AcceptanceHarness.Playwright.switch_browser_identity(fn next ->
        next
        |> visit("/test/atdd/login")
        |> click_link("Continue as isolated reviewer")
        |> click_link("Readership fixture")
        |> click_link("Inspect review history")
      end)
      |> assert_has("[data-review-target] > [data-review-count]",
        text: "2 cumulative reads",
        timeout: 10_000
      )
      |> assert_has("[data-review-target] > [data-review-count]", text: "staging 1")
      |> capture(
        "07-new-session",
        "Add one staging review from a new isolated identity",
        "Reload without increment, then sign in with a fresh browser identity and follow the same links"
      )

    assert ReviewStore.summary(project, target.target, target.revision, repo: Repo).environments ==
             %{"dev" => 1, "staging" => 1}

    conn =
      conn
      |> evaluate(
        "() => document.querySelector('#step-unseen').scrollIntoView()",
        [is_function: true],
        fn _ -> :ok end
      )
      |> assert_has("#step-unseen > [data-review-count]",
        text: "1 cumulative reads",
        timeout: 10_000
      )
      |> capture(
        "08-second-step",
        "Review the previously unseen outcome",
        "Scroll to Unseen outcome"
      )

    changed =
      update_in(
        data,
        ["scenarios", Access.at(0), "steps", Access.at(1)],
        &Map.put(&1, "description", "Revised outcome requires another review")
      )

    AdminStore.import_evidence_data!(changed, repo: Repo)

    conn =
      conn
      |> click_link("Run")
      |> click_link("Inspect review history")
      |> assert_has("#step-unseen > [data-review-count]",
        text: "Changed since human review",
        timeout: 10_000
      )
      |> assert_has("[data-review-target] > [data-review-count]",
        text: "1 cumulative reads",
        timeout: 10_000
      )
      |> capture(
        "09-changed",
        "Preserve history while marking the changed outcome unread",
        "Reopen the scenario after its second outcome changes"
      )
      |> evaluate(
        "() => document.querySelector('#step-unseen').scrollIntoView()",
        [is_function: true],
        fn _ -> :ok end
      )
      |> assert_has("#step-unseen > [data-review-count]",
        text: "Current revision viewed · 1 cumulative reads",
        timeout: 10_000
      )
      |> capture(
        "10-reviewed-change",
        "Review the changed revision once",
        "Scroll to the revised Unseen outcome"
      )

    conn
    |> evaluate(
      "() => { const key = 'acceptance-review-session'; const s = JSON.parse(sessionStorage.getItem(key)); s.last = Date.now() - 1800001; sessionStorage.setItem(key, JSON.stringify(s)); }",
      [is_function: true],
      fn _ -> :ok end
    )
    |> click_link("Run")
    |> click_link("Inspect review history")
    |> assert_has("[data-review-target] > [data-review-count]",
      text: "2 cumulative reads",
      timeout: 10_000
    )
    |> capture(
      "11-idle-session",
      "Count a new session after thirty minutes idle",
      "Expire the isolated session clock, return through Run and reopen the scenario"
    )

    Evidence.mark_scenario_success!(@scenario)
    Evidence.finalize!()
  end

  defp capture(conn, id, title, action),
    do: ReviewEvidence.capture(conn, @scenario, id, title, action)
end

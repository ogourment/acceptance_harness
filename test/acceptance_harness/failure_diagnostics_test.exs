defmodule AcceptanceHarness.FailureDiagnosticsTest do
  use ExUnit.Case, async: true

  alias AcceptanceHarness.FailureDiagnostics

  test "extracts ExUnit failure messages into evidence markdown" do
    log = """
    Running ExUnit with seed: 210624, max_cases: 1
    Excluding tags: [:test]
    Including tags: [:atdd]

    ....

      1) test user reviews Brevo subscription status through the account menu (AgileUWeb.Atdd.JourneyAdminNavigationTest)
         test/agile_u_web/atdd/journey_admin_navigation_atdd_test.exs:877
         Found element "#subscription-status" [text: "Status unavailable"]
         code: |> assert_brevo_status_available_when_configured()
         stacktrace:
           (phoenix_test_playwright 0.15.0) lib/phoenix_test/playwright.ex:662: PhoenixTest.Playwright.refute_has/3

    Finished in 17.0 seconds (1.4s async, 15.5s sync)
    323 tests, 1 failure, 315 excluded
    """

    markdown = FailureDiagnostics.markdown_for_log(log)

    assert markdown =~ "## Test Failures"

    assert markdown =~
             "### ❌ Outside scenario failure: test user reviews Brevo subscription status through the account menu"

    assert markdown =~ "Expected: ATDD harness completes without errors."

    assert markdown =~
             ~s(Failure: **Found element "#subscription-status" [text: "Status unavailable"]**)

    assert markdown =~
             "Code: **`|> assert_brevo_status_available_when_configured()`**"

    assert markdown =~ "```text"
    assert markdown =~ "PhoenixTest.Playwright.refute_has/3"
  end

  test "inserts failure markdown into the matching scenario and writes a summary" do
    tmp_dir = Path.join(System.tmp_dir!(), "agile-u-atdd-failures-#{System.unique_integer()}")
    log_path = Path.join(tmp_dir, "test.log")
    report_path = Path.join(tmp_dir, "e2e.md")
    summary_path = Path.join(tmp_dir, "failure_summary.txt")

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    File.mkdir_p!(tmp_dir)

    File.write!(report_path, """
    # Evidence

    ## Scenario Summary

    | # | Status | Scenario | Devices | Themes | Duration |
    | --- | --- | --- | --- | --- | --- |
    | 1 | ❌ | [Johari facilitator reveals a processed board for a five-person workshop](#-scenario-johari-facilitator-reveals-a-processed-board-for-a-five-person-workshop) | Desktop | dark | 0 ms |

    ## Run Contexts

    - Browser: Chromium

    ## ❌ Scenario: Johari facilitator reveals a processed board for a five-person workshop

    ### ✅ 1/2 - First captured step (42 ms)

    Last captured screenshot before the failure.

    Current URL: **https://staging.agile-u.com/journeys/example** - Theme: **dark** - Device: **Desktop** - Viewport: **1280x720** - Language: **English** - Click target: **Revealed board**

    ## ✅ Scenario: second scenario

    ### 1/1 - Complete step (10 ms)

    This scenario should remain after the first failure block.
    """)

    File.write!(log_path, """
      1) test five-person Johari workshop reaches a revealed processed board (ExampleTest)
         test/example_test.exs:12
         Expected page to have button
         code: assert_has(conn, "button")

    Finished in 0.1 seconds
    1 test, 1 failure
    """)

    assert :ok = FailureDiagnostics.append!(log_path, report_path, summary_path)
    report = File.read!(report_path)

    refute report =~ "## Test Failures Summary"
    refute report =~ "[Test Failures](#test-failures)"

    assert report =~ "## Failed Steps"

    assert report =~
             "- ❌ [Johari facilitator reveals a processed board for a five-person workshop](#-22---failed-step-test-five-person-johari-workshop-reaches-a-revealed-processed-board) - `test five-person Johari workshop reaches a revealed processed board` - Expected page to have button"

    assert report =~
             ~r/## Scenario Summary.*## Failed Steps.*## Run Contexts/s

    assert report =~
             ~r/## ❌ Scenario: Johari facilitator reveals a processed board for a five-person workshop.*### ✅ 1\/2 - First captured step.*### ❌ 2\/2 - Failed step: test five-person Johari workshop reaches a revealed processed board.*## ✅ Scenario: second scenario/s

    assert report =~
             ~r/### ❌ 2\/2 - Failed step: test five-person Johari workshop reaches a revealed processed board.*Expected: Johari facilitator reveals a processed board for a five-person workshop\.\n\n\n\nFailure: \*\*Expected page to have button\*\*/s

    assert report =~ "Failure: **Expected page to have button**"
    assert File.read!(summary_path) == "Expected page to have button"
  end

  test "writes failure count and capped previews when both output paths are provided" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "atdd-failure-output-contract-#{System.unique_integer()}")

    log_path = Path.join(tmp_dir, "test.log")
    report_path = Path.join(tmp_dir, "e2e.md")
    count_path = Path.join(tmp_dir, "failure_count.txt")
    previews_path = Path.join(tmp_dir, "failure_previews.json")

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    File.mkdir_p!(tmp_dir)

    File.write!(report_path, """
    # Evidence

    ## Run Contexts

    - Browser: Chromium
    """)

    failures_log =
      1..7
      |> Enum.map_join("\n", fn index ->
        """
        #{index}) test failing scenario #{index} (ExampleTest)
           test/example_test.exs:#{index + 9}
           Failure message #{index}
           code: assert_has(conn, "#missing-#{index}")
        """
      end)

    File.write!(log_path, """
    #{failures_log}

    Finished in 0.1 seconds
    7 tests, 7 failures
    """)

    assert :ok = FailureDiagnostics.append!(log_path, report_path, count_path, previews_path)

    assert File.read!(count_path) == "7"

    previews = File.read!(previews_path) |> Jason.decode!()
    assert is_list(previews)
    assert length(previews) == 5
    assert Enum.at(previews, 0)["scenario"] == "failing scenario 1"
    assert Enum.at(previews, 0)["message"] == "Failure message 1"
    assert Enum.at(previews, 0)["title"] == "failing scenario 1"
    assert Enum.at(previews, 0)["location"] == "test/example_test.exs:10"
  end

  test "formats capped HTML-safe Telegram failure previews" do
    previews =
      1..6
      |> Enum.map(fn index ->
        %{
          "scenario" => "scenario <#{index}>",
          "message" => "Could not find #flash-info & expected <success>",
          "location" => "test/example_test.exs:#{index}"
        }
      end)

    message = FailureDiagnostics.telegram_failure_previews(previews)

    assert message =~ "<b>Failure preview:</b>"
    assert message =~ "<b>scenario &lt;1&gt;</b>"
    assert message =~ "Could not find #flash-info &amp; expected &lt;success&gt;"
    assert message =~ "test/example_test.exs:1"
    refute message =~ "scenario &lt;6&gt;"
  end

  test "adds matching browser failure screenshots to the scenario failure step" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "agile-u-atdd-failure-screenshot-#{System.unique_integer()}")

    log_path = Path.join(tmp_dir, "test.log")
    report_path = Path.join(tmp_dir, "e2e.md")
    screenshot_dir = Path.join(tmp_dir, "screenshots")

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    File.mkdir_p!(screenshot_dir)

    File.write!(report_path, """
    # Evidence

    ## Run Contexts

    - Browser: Chromium

    ## ❌ Scenario: Johari facilitator reveals a processed board for a five-person workshop

    ### ✅ 1/2 - First captured step (42 ms)

    Last captured screenshot before the failure.

    Current URL: **https://staging.agile-u.com/journeys/example** - Theme: **dark**
    """)

    File.write!(
      Path.join(
        screenshot_dir,
        "AgileUWeb.Atdd.JourneyAdminNavigationTest.test_five_person_Johari_workshop_reaches_a_revealed_processed_board_123.png"
      ),
      "png"
    )

    File.write!(
      Path.join(
        screenshot_dir,
        "AgileUWeb.Atdd.JourneyAdminNavigationTest.test_five_person_Johari_workshop_reaches_a_revealed_processed_board_456.png"
      ),
      "png"
    )

    File.write!(
      Path.join(
        screenshot_dir,
        "AgileUWeb.Atdd.JourneyAdminNavigationTest.test_five_person_Johari_workshop_reaches_a_revealed_processed_board_789.png"
      ),
      ""
    )

    File.write!(log_path, """
      1) test five-person Johari workshop reaches a revealed processed board (ExampleTest)
         test/example_test.exs:12
         Expected page to have button
         code: assert_has(conn, "button")

    Finished in 0.1 seconds
    1 test, 1 failure
    """)

    assert :ok = FailureDiagnostics.append!(log_path, report_path)
    report = File.read!(report_path)

    assert report =~
             "### ❌ 2/2 - Failed step: test five-person Johari workshop reaches a revealed processed board"

    assert report =~
             "![Failure screenshot 1](screenshots/AgileUWeb.Atdd.JourneyAdminNavigationTest.test_five_person_Johari_workshop_reaches_a_revealed_processed_board_456.png)"

    refute report =~ "Open failure screenshot 1"

    refute report =~
             "![Failure screenshot 1](screenshots/AgileUWeb.Atdd.JourneyAdminNavigationTest.test_five_person_Johari_workshop_reaches_a_revealed_processed_board_123.png)"

    refute report =~
             "![Failure screenshot 1](screenshots/AgileUWeb.Atdd.JourneyAdminNavigationTest.test_five_person_Johari_workshop_reaches_a_revealed_processed_board_789.png)"

    assert report =~ "::: .failure-screenshot"
  end

  test "labels failures after the final captured step as after the scenario steps" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "agile-u-atdd-post-step-failure-#{System.unique_integer()}")

    log_path = Path.join(tmp_dir, "test.log")
    report_path = Path.join(tmp_dir, "e2e.md")
    screenshot_dir = Path.join(tmp_dir, "screenshots")

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    File.mkdir_p!(screenshot_dir)

    File.write!(report_path, """
    # Evidence

    ## Run Contexts

    - Browser: Chromium

    ## ❌ Scenario: Johari facilitator reveals a processed board for a five-person workshop

    ### ✅ 2/2 - Final captured step (42 ms)

    Last captured screenshot before the post-step failure.

    Current URL: **https://staging.agile-u.com/users/journeys** - Theme: **dark**
    """)

    File.write!(log_path, """
      1) test five-person Johari workshop reaches a revealed processed board (ExampleTest)
         test/example_test.exs:12
         Expected final post-step check to pass
         code: assert_has(conn, "#done")

    Finished in 0.1 seconds
    1 test, 1 failure
    """)

    assert :ok = FailureDiagnostics.append!(log_path, report_path)
    report = File.read!(report_path)

    assert report =~
             "### ❌ After 2/2 - Scenario failure: test five-person Johari workshop reaches a revealed processed board"

    refute report =~
             "### ❌ 2/2 - Failed step: test five-person Johari workshop reaches a revealed processed board"

    assert report =~
             "Current URL: **https://staging.agile-u.com/users/journeys** - Theme: **dark**"
  end

  test "uses pending step context when a documented step fails before capture" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "agile-u-atdd-pending-step-failure-#{System.unique_integer()}")

    log_path = Path.join(tmp_dir, "test.log")
    report_path = Path.join(tmp_dir, "e2e.md")
    pending_steps_path = Path.join(tmp_dir, "pending_steps.json")
    screenshot_dir = Path.join(tmp_dir, "screenshots")

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    File.mkdir_p!(screenshot_dir)

    File.write!(report_path, """
    # Evidence

    ## Run Contexts

    - Browser: Chromium

    ## ❌ Scenario: Johari multi-user evidence stays readable with three users

    ### ✅ 9/10 - User: Alice - Alice reviews her completed Johari board (42 ms)

    Last captured screenshot before the failed step.

    Current URL: **https://staging.agile-u.com/users/journeys** - Theme: **dark** - Device: **Tablet** - Viewport: **820x1180** - Language: **English**
    """)

    File.write!(
      pending_steps_path,
      Jason.encode!([
        %{
          "screenshot_name" => "14j-compact-benoit-my-journey-board.png",
          "title" => "Benoit reviews his completed Johari board",
          "description" =>
            "Benoit can review his own completed Johari board in French from My journeys on a phone-sized light-mode viewport.",
          "sequence" => 10,
          "metadata" => %{
            "scenario" => "Johari multi-user evidence stays readable with three users",
            "scenario_id" => "three-user",
            "step" => "10/10",
            "user" => "Benoit",
            "theme" => "light",
            "language" => "French",
            "device" => "Phone",
            "viewport" => "390x844",
            "click_target" => "Benoit completed board",
            "current_url" => "https://staging.agile-u.com/users/journeys?locale=fr"
          }
        }
      ])
    )

    File.write!(
      Path.join(screenshot_dir, "14j-compact-benoit-my-journey-board.png"),
      "pending step png"
    )

    File.write!(
      Path.join(
        screenshot_dir,
        "ExampleTest.test_three_user_Johari_workshop_documents_a_compact_multi_user_view_999.png"
      ),
      "test failure png"
    )

    File.write!(log_path, """
      1) test three-user Johari workshop documents a compact multi-user view (ExampleTest)
         test/example_test.exs:12
         Could not find element "#agile-u-temporary-atdd-second-step-failure" []
         code: |> assert_has("#agile-u-temporary-atdd-second-step-failure")

    Finished in 0.1 seconds
    1 test, 1 failure
    """)

    assert :ok = FailureDiagnostics.append!(log_path, report_path)
    report = File.read!(report_path)

    assert report =~
             "### ❌ 10/10 - User: Benoit - Benoit reviews his completed Johari board"

    assert report =~
             "- ❌ [Johari multi-user evidence stays readable with three users](#-1010---user-benoit---benoit-reviews-his-completed-johari-board) - `test three-user Johari workshop documents a compact multi-user view` - Could not find element"

    assert report =~
             "Benoit can review his own completed Johari board in French from My journeys on a phone-sized light-mode viewport."

    assert report =~
             "Expected: Benoit can review his own completed Johari board in French from My journeys on a phone-sized light-mode viewport."

    assert report =~
             "Current URL: **https://staging.agile-u.com/users/journeys?locale=fr** - Theme: **light** - Device: **Phone** - Viewport: **390x844** - Language: **French** - Click target: **Benoit completed board**"

    assert report =~
             "![Failure screenshot 1](screenshots/14j-compact-benoit-my-journey-board.png)"

    refute report =~
             "![Failure screenshot 1](screenshots/ExampleTest.test_three_user_Johari_workshop_documents_a_compact_multi_user_view_999.png)"

    refute report =~
             "### ❌ 10/10 - User: Benoit - Benoit reviews his completed Johari board (ExampleTest)"
  end

  test "uses pending scenario context when a scenario fails outside a documented step" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "agile-u-atdd-pending-scenario-failure-#{System.unique_integer()}"
      )

    log_path = Path.join(tmp_dir, "test.log")
    report_path = Path.join(tmp_dir, "e2e.md")
    pending_scenarios_path = Path.join(tmp_dir, "pending_scenarios.json")

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    File.mkdir_p!(tmp_dir)

    File.write!(report_path, """
    # Evidence

    ## Run Contexts

    - Browser: Chromium

    ## ❌ Scenario: Mistyped journey URL suggests the close active journey

    ### ✅ 1/2 - Mistyped journey URL suggests an active close match (42 ms)

    The first step passed.

    ### ✅ 2/2 - Suggested active journey opens (21 ms)

    The final documented step passed.
    """)

    File.write!(
      pending_scenarios_path,
      Jason.encode!([
        %{
          "id" => "fuzzy",
          "title" => "Mistyped journey URL suggests the close active journey",
          "sequence" => 1,
          "metadata" => %{
            "scenario" => "Mistyped journey URL suggests the close active journey",
            "scenario_id" => "fuzzy",
            "current_url" => "https://staging.agile-u.com/journeys/example",
            "theme" => "light",
            "device" => "Desktop"
          }
        }
      ])
    )

    File.write!(log_path, """
      1) test mistyped active journey URL suggests the close match (ExampleTest)
         test/example_test.exs:12
         Could not find element "#atdd-scenario-level-regression" []
         code: |> assert_has("#atdd-scenario-level-regression")

    Finished in 0.1 seconds
    1 test, 1 failure
    """)

    assert :ok = FailureDiagnostics.append!(log_path, report_path)
    report = File.read!(report_path)

    assert report =~
             "### ❌ Scenario failure: Mistyped journey URL suggests the close active journey"

    assert report =~ "Expected: Mistyped journey URL suggests the close active journey."

    assert report =~
             "Current URL: **https://staging.agile-u.com/journeys/example** - Theme: **light** - Device: **Desktop**"

    refute report =~ "### ❌ After 2/2"
  end

  test "adds a compact test failures link when a failure cannot be matched to a scenario" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "agile-u-atdd-orphan-failure-#{System.unique_integer()}")

    log_path = Path.join(tmp_dir, "test.log")
    report_path = Path.join(tmp_dir, "e2e.md")
    screenshot_dir = Path.join(tmp_dir, "screenshots")

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    File.mkdir_p!(screenshot_dir)

    File.write!(report_path, """
    # Evidence

    ## Scenario Summary

    | # | Status | Scenario | Devices | Themes | Duration |
    | --- | --- | --- | --- | --- | --- |
    | 1 | ✅ | [Covered scenario](#-scenario-covered-scenario) | Desktop | dark | 0 ms |

    ## Run Contexts

    - Browser: Chromium

    ## ✅ Scenario: Covered scenario
    """)

    File.write!(
      Path.join(screenshot_dir, "ExampleTest.test_unmatched_low_level_failure_999.png"),
      "generic failure png"
    )

    File.write!(log_path, """
      1) test unmatched low-level failure (ExampleTest)
         test/example_test.exs:12
         Unexpected worker crash

    Finished in 0.1 seconds
    1 test, 1 failure
    """)

    assert :ok = FailureDiagnostics.append!(log_path, report_path)
    report = File.read!(report_path)

    assert report =~
             ~r/\| 1 \| ✅ \| \[Covered scenario\].*\[Test Failures\]\(#test-failures\).*## Failed Steps.*## Run Contexts/s

    assert report =~
             "> ❌ Some failures happened outside documented scenarios. See [Test Failures](#test-failures) for full details."

    assert report =~ "## Test Failures"

    assert report =~
             "- ❌ [unmatched low-level failure](#test-failures) - `test unmatched low-level failure` - Unexpected worker crash"

    assert report =~ "### ❌ Outside scenario failure: test unmatched low-level failure"
    refute report =~ "Failure screenshot 1"
    refute report =~ "::: .failure-screenshot"
  end

  test "append! attaches the failure to the matching scenario in evidence.json" do
    tmp_dir = Path.join(System.tmp_dir!(), "atdd-evidence-failure-#{System.unique_integer()}")
    log_path = Path.join(tmp_dir, "test.log")
    report_path = Path.join(tmp_dir, "e2e.md")
    evidence_path = Path.join(tmp_dir, "evidence.json")

    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    File.mkdir_p!(tmp_dir)
    File.write!(report_path, "# Evidence\n\n## Run Contexts\n")

    File.write!(
      evidence_path,
      Jason.encode!(%{
        "scenarios" => [
          %{"id" => "checkout", "title" => "Participant checks out", "status" => "failure"},
          %{"id" => "other", "title" => "Other scenario", "status" => "success"}
        ]
      })
    )

    File.write!(log_path, """
      1) test participant CHECKS OUT (ExampleTest)
         test/example_test.exs:12
         Could not find element "[data-gap]"
         code: assert_has(conn, "[data-gap]")

    Finished in 0.1 seconds
    1 test, 1 failure
    """)

    assert :ok = FailureDiagnostics.append!(log_path, report_path)

    evidence = evidence_path |> File.read!() |> Jason.decode!()
    [checkout, other] = evidence["scenarios"]

    assert checkout["failure"]["message"] == ~s(Could not find element "[data-gap]")
    assert checkout["failure"]["code"] == ~s{assert_has(conn, "[data-gap]")}
    assert checkout["failure"]["location"] == "test/example_test.exs:12"
    refute Map.has_key?(other, "failure")
  end

  test "append! prefers the pending step's scenario id when matching failures" do
    tmp_dir = Path.join(System.tmp_dir!(), "atdd-evidence-pending-#{System.unique_integer()}")
    log_path = Path.join(tmp_dir, "test.log")
    report_path = Path.join(tmp_dir, "e2e.md")
    evidence_path = Path.join(tmp_dir, "evidence.json")

    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    File.mkdir_p!(tmp_dir)
    File.write!(report_path, "# Evidence\n\n## Run Contexts\n")

    File.write!(
      Path.join(tmp_dir, "pending_steps.json"),
      Jason.encode!([
        %{
          "title" => "Filling the payment form",
          "description" => "About to pay",
          "screenshot_name" => "pay.png",
          "metadata" => %{"scenario_id" => "checkout", "scenario" => "participant pays by card"}
        }
      ])
    )

    File.write!(
      evidence_path,
      Jason.encode!(%{
        "scenarios" => [
          %{
            "id" => "checkout",
            "title" => "A very different display title",
            "status" => "failure"
          }
        ]
      })
    )

    File.write!(log_path, """
      1) test participant pays by card (ExampleTest)
         test/example_test.exs:30
         Payment button missing
         code: assert_has(conn, "#pay")

    Finished in 0.1 seconds
    1 test, 1 failure
    """)

    assert :ok = FailureDiagnostics.append!(log_path, report_path)

    evidence = evidence_path |> File.read!() |> Jason.decode!()
    [checkout] = evidence["scenarios"]

    assert checkout["failure"]["message"] == "Payment button missing"
    assert checkout["failure"]["pending_step"]["title"] == "Filling the payment form"
  end

  test "scenario aliases may carry the registry entry instead of only its title" do
    previous = Application.fetch_env!(:acceptance_harness, :harness)

    on_exit(fn ->
      Application.put_env(:acceptance_harness, :harness, previous)
    end)

    Application.put_env(
      :acceptance_harness,
      :harness,
      Keyword.put(previous, :scenario_title_aliases, %{
        "technical test title" => %{
          "id" => "scenario-id",
          "title" => "Readable scenario title",
          "status" => "ignored"
        }
      })
    )

    tmp_dir = Path.join(System.tmp_dir!(), "scenario-alias-map-#{System.unique_integer()}")
    log_path = Path.join(tmp_dir, "test.log")
    report_path = Path.join(tmp_dir, "e2e.md")
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    File.mkdir_p!(tmp_dir)
    File.write!(report_path, "# Evidence\n")

    File.write!(
      log_path,
      """
        1) test technical test title (ExampleTest)
           test/example_test.exs:12
           Browser navigation failed
           code: visit(conn, "/example")

      Finished in 0.1 seconds
      1 test, 1 failure
      """
    )

    assert [%{scenario: "Readable scenario title"}] =
             FailureDiagnostics.diagnose(log_path, report_path)
  end

  test "structured scenario metadata does not crash pending-step matching" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "structured-pending-scenario-#{System.unique_integer()}")

    log_path = Path.join(tmp_dir, "test.log")
    report_path = Path.join(tmp_dir, "e2e.md")
    File.mkdir_p!(tmp_dir)
    File.write!(report_path, "# Evidence\n")

    File.write!(
      Path.join(tmp_dir, "pending_steps.json"),
      Jason.encode!([
        %{
          "title" => "Approve batch",
          "description" => "Approval appears",
          "sequence" => 1,
          "metadata" => %{
            "scenario" => %{"id" => "email-guard", "title" => "Email approval guard"}
          }
        }
      ])
    )

    File.write!(log_path, """
      1) test Email approval guard (ExampleTest)
         test/example_test.exs:12
         Expected approval
         code: assert_has(view, "#approval")

    Finished in 0.1 seconds
    1 test, 1 failure
    """)

    assert [%{}] = FailureDiagnostics.diagnose(log_path, report_path)
  end

  test "append! matches evidence scenario by source file when titles differ" do
    tmp_dir = Path.join(System.tmp_dir!(), "atdd-evidence-source-#{System.unique_integer()}")
    log_path = Path.join(tmp_dir, "test.log")
    report_path = Path.join(tmp_dir, "e2e.md")
    evidence_path = Path.join(tmp_dir, "evidence.json")

    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    File.mkdir_p!(tmp_dir)
    File.write!(report_path, "# Evidence\n\n## Run Contexts\n")

    File.write!(
      evidence_path,
      Jason.encode!(%{
        "scenarios" => [
          %{
            "id" => "sessions-session-full-desktop",
            "title" => "A full session refuses new registrations",
            "status" => "failure",
            "metadata" => %{
              "source_file" => "test/ecojeux_web/atdd/sessions_session_full_desktop_atdd_test.exs"
            }
          }
        ]
      })
    )

    File.write!(log_path, """
      1) test a full session blocks a new registration (EcojeuxWeb.Atdd.SessionFullTest)
         test/ecojeux_web/atdd/sessions_session_full_desktop_atdd_test.exs:87
         Expected button to be disabled
         code: assert_has(session, "button[disabled]")

    Finished in 0.1 seconds
    1 test, 1 failure
    """)

    assert :ok = FailureDiagnostics.append!(log_path, report_path)

    evidence = evidence_path |> File.read!() |> Jason.decode!()
    [scenario] = evidence["scenarios"]

    assert scenario["failure"]["message"] == "Expected button to be disabled"

    assert scenario["failure"]["location"] ==
             "test/ecojeux_web/atdd/sessions_session_full_desktop_atdd_test.exs:87"
  end
end

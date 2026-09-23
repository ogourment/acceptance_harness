defmodule AcceptanceHarness.EvidenceFacadeTest.Client do
  use AcceptanceHarness.EvidenceFacade
end

defmodule AcceptanceHarness.EvidenceFacadeTest.PlaywrightClient do
  use AcceptanceHarness.Playwright.ATDDCase, async: false
end

defmodule AcceptanceHarness.EvidenceFacadeTest do
  use ExUnit.Case, async: true

  @delegates [
    {:start_scenario_runtime!, [0]},
    {:record_current_scenario_runtime, [1]},
    {:reset!, [1, 2, 3]},
    {:record_step, [3, 4]},
    {:record_pending_step, [3, 4]},
    {:record_pending_scenario, [1, 2]},
    {:mark_scenario_success!, [1]},
    {:mark_scenario_ignored_failure!, [2, 3]},
    {:record_scenario_runtime, [2]},
    {:finalize!, [0]},
    {:report_path, [0]},
    {:evidence_json_path, [0]},
    {:report_json_path, [0]}
  ]

  test "generates the explicit evidence façade" do
    for {name, arities} <- @delegates,
        arity <- arities do
      assert function_exported?(AcceptanceHarness.EvidenceFacadeTest.Client, name, arity),
             "expected #{name}/#{arity} to be delegated"
    end
  end

  test "delegated path functions call the harness" do
    assert AcceptanceHarness.EvidenceFacadeTest.Client.report_path() ==
             AcceptanceHarness.Evidence.report_path()

    assert AcceptanceHarness.EvidenceFacadeTest.Client.evidence_json_path() ==
             AcceptanceHarness.Evidence.evidence_json_path()

    assert AcceptanceHarness.EvidenceFacadeTest.Client.report_json_path() ==
             AcceptanceHarness.Evidence.report_json_path()
  end

  test "the browser ATDD case composes browser support and evidence" do
    assert function_exported?(AcceptanceHarness.EvidenceFacadeTest.PlaywrightClient, :reset!, 3)

    assert function_exported?(
             AcceptanceHarness.EvidenceFacadeTest.PlaywrightClient,
             :record_step,
             4
           )
  end
end

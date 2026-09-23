defmodule AcceptanceHarness.Playwright.Case do
  @moduledoc """
  Shared case template for isolated Playwright acceptance scenarios.

  `PhoenixTest.Playwright.Case` creates and closes a distinct browser context
  for every test. Using this wrapper makes that scenario boundary explicit and
  imports the harness helpers used when one scenario intentionally changes
  browser identity.

  Use `AcceptanceHarness.Playwright.ATDDCase` when the scenario also needs the
  app-local evidence façade.
  """

  defmacro __using__(opts) do
    quote do
      use PhoenixTest.Playwright.Case, unquote(opts)

      setup do
        AcceptanceHarness.Evidence.start_scenario_runtime!()
        :ok
      end

      import AcceptanceHarness.Playwright,
        only: [reset_browser_state: 1, switch_browser_identity: 2]
    end
  end
end

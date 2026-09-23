defmodule AcceptanceHarness.Playwright.ATDDCase do
  @moduledoc """
  Convenience case for browser acceptance scenarios that record evidence.

  It composes `AcceptanceHarness.Playwright.Case` with
  `AcceptanceHarness.EvidenceFacade`. Use `AcceptanceHarness.Playwright.Case`
  directly when a test needs browser support without the evidence façade.
  """

  defmacro __using__(opts \\ []) do
    quote do
      use AcceptanceHarness.Playwright.Case, unquote(opts)
      use AcceptanceHarness.EvidenceFacade
    end
  end
end

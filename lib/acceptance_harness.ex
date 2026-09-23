defmodule AcceptanceHarness do
  @moduledoc """
  Shared acceptance-test execution helpers.
  """

  @doc """
  Runs a declared ignored scenario without failing ExUnit for its known error.

  Ordinary exceptions are preserved in acceptance evidence. Exits and throws
  are not swallowed because they generally signal infrastructure failures.
  """
  def ignore(%{status: :ignored} = scenario, function) when is_function(function, 0) do
    function.()
    :ok
  rescue
    exception ->
      AcceptanceHarness.Evidence.mark_scenario_ignored_failure!(
        scenario,
        exception |> Exception.message() |> String.trim(),
        Exception.format_stacktrace(__STACKTRACE__)
      )

      :ignored
  end

  def ignore(scenario, _function) do
    raise ArgumentError,
          "ignore/2 requires a scenario declared with status: :ignored, got: #{inspect(scenario)}"
  end
end

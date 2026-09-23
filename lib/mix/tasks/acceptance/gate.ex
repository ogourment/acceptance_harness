defmodule Mix.Tasks.Acceptance.Gate do
  @moduledoc "Checks whether acceptance evidence can gate production deployment."
  use Mix.Task

  @shortdoc "Checks acceptance gate inputs"

  @impl Mix.Task
  def run([]) do
    AcceptanceHarness.Gate.check!()
  end

  def run([status_path, report_path]) do
    AcceptanceHarness.Gate.check!(status_path, report_path)
  end

  def run(_args) do
    Mix.raise("usage: mix acceptance.gate [STATUS_PATH REPORT_PATH]")
  end
end

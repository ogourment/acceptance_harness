defmodule Mix.Tasks.Acceptance.AppendFailures do
  @moduledoc "Appends ExUnit failure diagnostics to an acceptance evidence report."
  use Mix.Task

  @shortdoc "Appends acceptance failure diagnostics"

  @impl Mix.Task
  def run([log_path, report_path]) do
    AcceptanceHarness.FailureDiagnostics.append!(log_path, report_path)
  end

  def run([log_path, report_path, count_path, previews_path]) do
    AcceptanceHarness.FailureDiagnostics.append!(log_path, report_path, count_path, previews_path)
  end

  def run([log_path, report_path, summary_path]) do
    AcceptanceHarness.FailureDiagnostics.append!(log_path, report_path, summary_path)
  end

  def run(_args) do
    Mix.raise(
      "usage: mix acceptance.append_failures LOG_PATH REPORT_PATH [COUNT_PATH] [PREVIEW_PATH] \n" <>
        "COUNT_PATH only: legacy single-summary output\n" <>
        "COUNT_PATH + PREVIEW_PATH: count + JSON preview payload"
    )
  end
end

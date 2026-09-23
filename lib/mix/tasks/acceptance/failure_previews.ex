defmodule Mix.Tasks.Acceptance.FailurePreviews do
  @moduledoc "Formats acceptance failure previews for HTML-capable notifications."
  use Mix.Task

  alias AcceptanceHarness.FailureDiagnostics

  @shortdoc "Formats acceptance failure previews for Telegram"

  @impl Mix.Task
  def run([previews_path]) do
    previews_path
    |> File.read!()
    |> Jason.decode!()
    |> FailureDiagnostics.telegram_failure_previews()
    |> IO.write()
  end

  def run(_args), do: Mix.raise("usage: mix acceptance.failure_previews PREVIEWS_PATH")
end

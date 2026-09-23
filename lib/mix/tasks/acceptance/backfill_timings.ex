defmodule Mix.Tasks.Acceptance.BackfillTimings do
  @shortdoc "Backfills retained acceptance timing summaries"

  @moduledoc """
  Recomputes scenario documented-step timing from retained step metadata.

      mix acceptance.backfill_timings --dry-run
      mix acceptance.backfill_timings --run-id RUN_ID

  Elapsed scenario or pipeline timing that was never captured remains unknown.
  The task never invents zeroes and performs no external API requests.
  """

  use Mix.Task

  alias AcceptanceHarness.AdminStore

  @impl Mix.Task
  def run(argv) do
    {opts, _args, _invalid} =
      OptionParser.parse(argv, strict: [run_id: :string, dry_run: :boolean, repo: :string])

    Mix.Task.run("app.start")

    store_opts =
      [dry_run: Keyword.get(opts, :dry_run, false)]
      |> maybe_put(:run_id, Keyword.get(opts, :run_id))
      |> maybe_put(:repo, resolve_repo(Keyword.get(opts, :repo)))

    result = AdminStore.backfill_timing_summaries!(store_opts)
    mode = if result.dry_run?, do: "DRY RUN", else: "APPLIED"

    Mix.shell().info(
      "#{mode} · run=#{result.run_id || "all"} · scenarios=#{result.scenarios} · " <>
        "documented_step_ms=#{result.documented_step_ms}"
    )
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
  defp resolve_repo(nil), do: nil
  defp resolve_repo(name), do: Module.concat([name])
end

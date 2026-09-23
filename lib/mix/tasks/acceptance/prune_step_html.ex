defmodule Mix.Tasks.Acceptance.PruneStepHtml do
  @shortdoc "Clears stored raw page HTML for acceptance runs beyond the retention window"

  @moduledoc """
  Clears `page_html` for acceptance evidence runs older than the retention
  window, leaving every other evidence record intact.

  Raw per-step HTML is the heaviest column in the evidence schema. On Ecojeux
  staging it reached 1.63GB of a 1.84GB table while `page_text` for the same
  47k steps was 43MB. Because the database is dumped hourly, that one column
  made each backup snapshot ~1.1GB and repeatedly filled the disk.

  Runs, scenarios, steps, screenshots, artifacts, metadata and work
  run and scenario metadata are untouched, and `page_text` is kept so evidence
  stays searchable.

      # report without writing
      mix acceptance.prune_step_html --dry-run

      # apply the default 7-day window
      mix acceptance.prune_step_html

      # custom window
      mix acceptance.prune_step_html --keep-days 14

  Run it after importing evidence, so the window is evaluated against the newest
  run. The repo comes from `--repo` or the `:acceptance_harness` application's
  configured repo.
  """

  use Mix.Task

  alias AcceptanceHarness.AdminStore

  @impl Mix.Task
  def run(argv) do
    {opts, _argv, _invalid} =
      OptionParser.parse(argv,
        strict: [keep_days: :integer, dry_run: :boolean, repo: :string]
      )

    Mix.Task.run("app.start")

    store_opts =
      [dry_run: Keyword.get(opts, :dry_run, false)]
      |> maybe_put(:keep_days, Keyword.get(opts, :keep_days))
      |> maybe_put(:repo, resolve_repo(Keyword.get(opts, :repo)))

    summary = AdminStore.prune_step_html!(store_opts)

    mode = if summary.dry_run?, do: "DRY RUN", else: "APPLIED"

    Mix.shell().info(
      "#{mode} · keep_days=#{summary.keep_days} · runs=#{summary.runs} · " <>
        "steps=#{summary.steps} · reclaimed=#{format_bytes(summary.bytes_reclaimed)}"
    )

    if not summary.dry_run? and summary.bytes_reclaimed > 0 do
      Mix.shell().info(
        "Postgres reuses the freed pages for new rows. Run VACUUM FULL or " <>
          "pg_repack only if the table must shrink on disk immediately."
      )
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp resolve_repo(nil), do: nil
  defp resolve_repo(name), do: Module.concat([name])

  defp format_bytes(bytes) when bytes >= 1_073_741_824,
    do: "#{Float.round(bytes / 1_073_741_824, 2)}GB"

  defp format_bytes(bytes) when bytes >= 1_048_576,
    do: "#{Float.round(bytes / 1_048_576, 1)}MB"

  defp format_bytes(bytes), do: "#{bytes}B"
end

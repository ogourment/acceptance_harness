defmodule Mix.Tasks.Acceptance.UpdateAgents do
  @moduledoc """
  Adds or refreshes AcceptanceHarness ATDD authoring and worktree guidance in
  a consumer application's `AGENTS.md`.

  The task owns only the content between its HTML markers, so local consumer
  instructions remain intact.
  """
  use Mix.Task

  @shortdoc "Updates a consumer AGENTS.md with ATDD authoring guidance"

  @start_marker "<!-- acceptance-harness:atdd-worktree-ports:start -->"
  @end_marker "<!-- acceptance-harness:atdd-worktree-ports:end -->"
  @guidance_version "0.11.2"

  @guidance """
  #{@start_marker}
  <!-- acceptance-harness:guidance-version:#{@guidance_version} -->
  ## AcceptanceHarness contract

  This is the short entry point, not a replacement for the full requirements.
  Before related work, read the relevant sections of
  [the acceptance contract](__HARNESS_DOCS__/acceptance-contract.md) and
  [the compact review guide](__HARNESS_DOCS__/approval_review_bundle_example.md)
  from the pinned harness checkout. If unavailable, locate/fetch that dependency;
  do not silently proceed from this summary alone. User instructions take priority.

  ### Specify before implementing

  - Scenarios are product contracts. Before changing scenario intent, steps,
    registry, captures or assertions: identify affected IDs/files, retrieve current
    step evidence, propose exact before/after outcomes, and obtain explicit approval
    of those named changes. Code approval is not scenario approval. Never weaken
    expected outcomes to make tests pass. Show exact diffs and new evidence before
    committing/pushing. Observation-only robustness fixes need no separate approval.
  - Agree examples, run a meaningful failing acceptance journey, implement, then
    rerun it. A design mockup communicates intent; it is not executed evidence.
    Automated checks and human visual approval are distinct.
  - Exercise complete human journeys through visible controls, with triggering
    actions before their results. Assert persisted state and applicable messages,
    personal/admin views, counts, identity, reload, retries and deduplication from
    the activity actually performed. Do not seed final outcomes or depend on another
    scenario. Label incomplete coverage explicitly; one-step smoke is not a journey.
  - Preserve known defects as `:ignored` with reasons and executed partial evidence;
    `:skipped` is only for unavailable environment/platform capabilities. Neither is
    passed. Register pending steps before potentially failing expected actions.

  ### Evidence and isolation

  - Browser scenarios use `AcceptanceHarness.Playwright.Case`; changing actors uses
    `switch_browser_identity/2`. Isolate DB state, mailboxes, jobs, config and uploads
    as well as browser identities. Never delete unowned shared artifacts.
  - Use the shared full-page capture helper with viewport chrome pin/unpin; retain
    PNG and source HTML, inspect every capture, and verify served assets belong to
    the active checkout. Declare actual surface/device/theme and capability gaps.
  - Name external systems, account/environment, fake/sandbox/live mode, outbound
    data, effects and cleanup. Verify safe logs/IDs/status/retries and DB effects.
    Show actual captured mail in a message reader; a preview is not delivery proof.
  - Relational migrations need a colored union schema diff from clean isolated
    before/after databases. Keep checked-in diagrams current without rewriting
    them during unit tests. No schema change needs only one concise statement.

  ### Compact human review

  - Keep one watched `docs/YYYY-MM-DD-<topic>.html` per goal, updated in place.
    Default to four summary items (at most six when justified), with complete
    evidence/history in an optional detailed sequence. Never force a long history
    deck before the current decision. Preserve approval history before compacting.
  - Every item has a stable ID, one ask and a state: `NEW — REVIEW`,
    `CHANGED — REVIEW AGAIN`, `APPROVED` or `UNCHANGED`. Page and selected deck
    sequence match exactly. Provide Start presentation, one position counter,
    keyboard/Previous/Next navigation, Next at far right and no stale images.
  - Include implementation reuse/simplification, material risks, external/schema
    impact and precise approval scope, proportionate to the change. Explain why
    and expected value for important investment decisions.
  - Show exact semantic color diffs for scenarios AND changed governing documents:
    UI/style guidance, AGENTS/CLAUDE, policies, runbooks, architecture and plans.
    Green additions, red removals, amber hunks; raw links are secondary. Keep these
    readable in the page and optional detail deck, not hidden in an unstyled tab.
  - Preserve immutable screenshots and clean originals; changed states use one
    Before/After composite, unchanged states one image. Put labels outside images
    and overlays around changed regions. Follow the guide's accessible zoom/fit
    controls and verify every deck sequence in a real browser.
  - The reviewer owns local xopen; provide the canonical absolute path. For requested
    tailnet review, use one explicit reachable server and verify it from the target
    device. Never redirect the watched page or reuse another worktree's server.
    Before handoff, validate with xopen's exact serving contract—not a differently
    rooted static server—and assert every local image and linked resource loads
    without 404s. A rendered HTML shell is not a verified review bundle.
    Preview-tool chrome must yield to the reviewed UI: while a visible modal or
    lightbox is open, xopen controls must not cover its controls or evidence.

  ### Fast delivery, complete coverage

  - Review in dev; run matching ATDD once and reuse valid evidence. Require bounded
    safety checks before staging, full/deeper validation afterward and before prod.
    Document exceptional repeat runs; retain environment-specific external checks.
  - Area markers (e.g. #participants) and path maps only add coverage. Unknown/shared
    impact selects full required coverage. Assemble phases by stable scenario ID.
  - Use separate endpoint ports/base URLs AND test databases (`MIX_TEST_PARTITION`)
    for concurrent worktrees; never share mutable builds across checkouts.
  - Keep tmp/ ignored and disposable; durable review artifacts belong in docs/.
    After harness updates run `mix acceptance.update_agents`; keep
    `mix acceptance.update_agents --check` in normal validation.
  #{@end_marker}
  """

  @impl Mix.Task
  def run([]), do: update!(".", false)

  def run(["--check"]), do: update!(".", true)
  def run(["--check", consumer_dir]), do: update!(consumer_dir, true)
  def run([consumer_dir]), do: update!(consumer_dir, false)

  def run(_args),
    do: Mix.raise("usage: mix acceptance.update_agents [--check] [CONSUMER_DIR]")

  defp update!(consumer_dir, check?) do
    path = Path.join(consumer_dir, "AGENTS.md")

    contents =
      case File.read(path) do
        {:ok, contents} -> contents
        {:error, :enoent} -> Mix.raise("#{path} does not exist")
        {:error, reason} -> Mix.raise("could not read #{path}: #{:file.format_error(reason)}")
      end

    ensure_tmp_policy!(consumer_dir, check?)
    updated = replace_guidance(contents, consumer_dir)

    if check? and updated != contents do
      Mix.raise("#{path} has stale AcceptanceHarness guidance; run mix acceptance.update_agents")
    else
      write_update(path, contents, updated, check?)
    end
  end

  defp ensure_tmp_policy!(consumer_dir, check?) do
    tracked = tracked_tmp_files(consumer_dir)

    if tracked != [] do
      examples = tracked |> Enum.take(10) |> Enum.map_join("\n", &"  - #{&1}")
      suffix = if length(tracked) > 10, do: "\n  - …", else: ""

      Mix.raise("""
      #{consumer_dir} tracks files under tmp/, which must remain disposable and ignored:
      #{examples}#{suffix}
      Move durable approved evidence or summaries to docs/ before rerunning this task.
      """)
    end

    ensure_tmp_ignored!(consumer_dir, check?)
  end

  defp tracked_tmp_files(consumer_dir) do
    if File.dir?(Path.join(consumer_dir, ".git")) do
      case System.cmd("git", ["-C", consumer_dir, "ls-files", "-z", "--", "tmp"]) do
        {output, 0} -> String.split(output, <<0>>, trim: true)
        {output, status} -> Mix.raise("git ls-files failed (#{status}): #{String.trim(output)}")
      end
    else
      []
    end
  end

  defp ensure_tmp_ignored!(consumer_dir, check?) do
    path = Path.join(consumer_dir, ".gitignore")
    contents = if File.exists?(path), do: File.read!(path), else: ""

    ignored? =
      contents
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.any?(&(&1 in ["/tmp/", "tmp/"]))

    cond do
      ignored? ->
        :ok

      check? ->
        Mix.raise("#{path} must ignore /tmp/; run mix acceptance.update_agents")

      true ->
        separator = if contents == "" or String.ends_with?(contents, "\n"), do: "", else: "\n"
        File.write!(path, contents <> separator <> "/tmp/\n")
        Mix.shell().info("Updated #{path} to ignore disposable tmp/ artifacts.")
    end
  end

  defp write_update(path, contents, updated, check?) do
    if updated != contents do
      File.write!(path, updated)
      Mix.shell().info("Updated #{path} with AcceptanceHarness ATDD guidance.")
    else
      verb = if check?, do: "has", else: "already has"
      Mix.shell().info("#{path} #{verb} current AcceptanceHarness ATDD guidance.")
    end
  end

  defp replace_guidance(contents, consumer_dir) do
    docs =
      if File.regular?(Path.join(consumer_dir, "lib/mix/tasks/acceptance/update_agents.ex")),
        do: "docs",
        else: "deps/acceptance_harness/docs"

    block = String.replace(@guidance, "__HARNESS_DOCS__", docs) |> String.trim_trailing()
    block = block <> "\n"

    case String.split(contents, @start_marker, parts: 2) do
      [before, after_start] ->
        case String.split(after_start, @end_marker, parts: 2) do
          [_old, suffix] ->
            String.trim_trailing(before) <> "\n\n" <> block <> String.trim_leading(suffix, "\n")

          [_unclosed] ->
            Mix.raise("AGENTS.md has an unclosed AcceptanceHarness ATDD guidance block")
        end

      [_unchanged] ->
        String.trim_trailing(contents) <> "\n\n" <> block
    end
  end
end

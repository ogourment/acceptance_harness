# Changelog

## 0.11.3 - 2026-09-25

- Serve mdopen's watched Markdown page when its source is outside the rendered
  output directory, including the generated stylesheet and live controls.

## 0.11.2 - 2026-09-22

- Hide xopen's floating status controls while a visible native dialog or ARIA
  modal/lightbox is open, then restore them when it closes, so preview tooling
  cannot cover the reviewed interface's controls or evidence.

## 0.11.1 - 2026-09-22

- Resolve nested review-bundle assets relative to the watched HTML document
  while retaining repository-root access for linked evidence and Markdown.
- Require pre-handoff validation through xopen's exact serving contract and
  reject missing local images or linked resources instead of accepting an HTML
  shell verified through a differently rooted server.

## 0.11.0 - 2026-09-20

- Capture exact CI job pending timestamps and separate runner-queue duration,
  with fractional precision and explicit missing-data reasons.
- Add project-scoped review receipts, cumulative environment provenance,
  browser visibility tracking, receipt exchange and an advisory coverage report.
- Bundle portable xopen/mdopen preview tools and compact the Phoenix review UI.
- Add a SQLite evidence viewer with shared browser tracking and idempotent
  receipt exchange with the Phoenix/PostgreSQL store.
- Add an artifact-only gate command that needs Python, without fetching
  application dependencies, compiling Elixir, or rerunning acceptance scenarios.
- Shorten onboarding and align generated guidance with development-first review,
  post-staging deep checks, evidence reuse and explicit platform capabilities.

## 0.10.8 - 2026-09-19

- Require semantic in-page color diffs for important standards, guidance,
  manuals, runbooks, architecture documents, and other durable text that
  governs future human or agent work.

## 0.10.7 - 2026-09-18

- Preserve legacy plain strings while repairing double-encoded JSONB evidence
  columns, preventing evidence-store installation from failing on older rows.

## 0.10.6 - 2026-09-12

- Flag one-step ATDD scenarios as a coverage smell; require sequential
  value-adding flows and closure over real persisted, personal, dashboard,
  delivery and metric side effects. Require honest coverage-incomplete flags
  even when tests pass, without conflating coverage gaps with ignored defects
  or skipped environments. Consumers should reinject guidance and audit
  existing scenarios; no schema or application behavior changes are required.

## 0.10.5 - 2026-09-12

- Require a planned implementation preview in acceptance reviews, explicitly
  identifying reuse, simplification, necessary new code, duplicated
  responsibilities and verified infrastructure configuration.

## 0.10.4 - 2026-09-10

- Let consumers commit reviewed ATDD evidence without a second explicit
  approval, while retaining explicit approval for scenario-contract changes.

## 0.10.3 - 2026-09-09

- Render exact PostgreSQL foreign-key column relationships for composite keys,
  including standalone unique-index targets and reused constraint names.

## 0.10.2 - 2026-09-08

- Make `mix acceptance.update_agents` establish `/tmp/` as disposable ignored
  space and refuse consumer repositories that already track files beneath it.

## 0.10.0 - 2026-09-05

- Retire review Comments and scenario/step work statuses from the Phoenix review
  UI, persistence model, configuration, JavaScript assets, and runtime APIs.
- Keep imported acceptance runs, scenarios, steps, screenshots, rendered pages,
  source changes, schema changes, failures, filtering, and retention as the
  focused read-only review surface.
- Remove obsolete Comment and work-status tables during admin-store installation;
  consumers should preserve any needed history before applying their forward
  migration.

## 0.9.14 - 2026-09-04

- Dispatch optional Ecto/Postgres integration dynamically so database-free
  consumers compile without undefined-module warnings.

## 0.9.13 - 2026-09-04

- Keep each review goal in one topic-named, watched HTML document whose page
  and presentation modes contain the same requirements, evidence, progress,
  and approval state.
- Require a Git checkpoint before compacting an overgrown review document, then
  retain only concise completed context and small thumbnails while preserving
  links to full-resolution evidence.

## 0.9.12 - 2026-09-03

- Require patched Phoenix LiveView and Plug release lines for consumers, and
  update the development and example locks to patched LiveView, Plug, and
  Postgrex versions.

## 0.9.11 - 2026-09-03

- Add an explicit evidence façade and a combined Playwright ATDD case so
  consumers can configure browser evidence tests with less boilerplate.

## 0.9.10 - 2026-09-03

- Keep the internal Postgres test repo optional so database-free Phoenix
  consumers can compile AcceptanceHarness in their test environment without
  adding unused Ecto dependencies.

## 0.9.9 — 2026-09-03

- Require a single native-width side-by-side composite for changed before/after
  screenshots so both states zoom and scroll together, while retaining links to
  both clean source images.

## v0.9.8

- Require page/deck information and numbering parity, single-fire sequential
  navigation, cleared text-only slides, styled control grouping, browser-checked
  HTML annotations, visual proposal inserts, and same-slide before/after pairs
  for previous-release evidence.
- Add a complete-workflow review model alongside the focused canonical example.

## v0.9.7

- Keep one watched review path throughout a goal, render every exact scenario
  diff as an in-page colored diff, pair changed final evidence before/after,
  and persist the reviewer's image-fit radio choice across slides.

## v0.9.6

- Remove stale `file://` review instructions that contradicted the raw absolute
  filesystem path and reviewer-owned `xopen --watch` workflow.

## v0.9.5

- Keep oversized evidence images anchored to the left so zoomed schema diagrams
  can scroll to both edges, and place forward presentation navigation at the
  far right.
- Require self-contained watched review roots, one slide/preview surface,
  stable review-state labels, raw filesystem handoff paths, and browser-verified
  scrollable zoom.

## v0.9.4

- Preserve multiline table-cell markup when coloring consolidated relational
  schema diffs, so changed columns retain their green, red, or amber review
  treatment.
- Keep the injected consumer guidance version aligned with the package release.

## v0.8.7

- Require scenarios to disclose touched external systems, side effects and
  cleanup, and to verify interaction logging, including intentional personal
  context and log levels during production ramp-up.

## v0.8.6

- Require scenarios to prove human navigation from known states, derive reports
  from scenario-performed activity, render relational schema changes from
  isolated before/after databases, and verify complete image lightboxes.

## v0.8.0

- Select a conservative fast acceptance subset from canonical scenario metadata,
  commit-area markers, changed paths, and an always-run scenario set; unknown or
  ambiguous impact falls back to the complete suite.
- Assemble phased acceptance evidence by stable scenario identity so the final
  gate and review surface contain one authoritative result per scenario.
- Version the injected consumer guidance and support a check-only task that
  fails when `AGENTS.md` has not been refreshed after a harness upgrade.
- Accept structured scenario metadata while matching failure diagnostics.

## v0.7.12

- Detect scenario changes in historical evidence that lacks source checksums by
  comparing the ordered step titles and descriptions. Screenshots, URLs,
  durations, and other runtime evidence remain excluded from this fallback.

## v0.7.11

- Allow scenarios that share an Elixir source file to identify their exact
  `test "..."` block with `source_test`, producing scenario-specific checksums,
  source snapshots, and change diffs instead of flagging every scenario in the
  file.
- Fail evidence setup when a declared `source_test` is missing, duplicated, or
  points to a non-Elixir source file so change tracking cannot silently vanish.

## v0.7.6

- Record ordered message timelines with relative timing, transport operations,
  lifecycle states, and visible text in the framework-neutral evidence v1
  bundle.
- Render message timelines in static and live review surfaces and index every
  frame's visible text for live evidence search.

## v0.7.5

- Render schema changes as a unified copy of the original domain graph,
  preserving clusters, layout, and relationship edges while colour-marking
  added, changed, and removed elements.
- Keep Graphviz diagnostics outside generated SVG payloads so schema evidence
  remains valid XML and opens directly in browsers.

## v0.7.4

- Include each captured step URL in the acceptance run search, so reviewers can
  find scenarios by paths such as `/admin/facilitators`.

## v0.6.8

- Link changed-domain names directly to their schema SVG artifacts, including
  artifacts retained by historical runs and removed domains.

## v0.6.7

- Show every column, data type, primary-key marker, and nullability constraint
  in generated schema-domain diagrams.
- Stabilize full-page browser evidence screenshots by normalizing fixed and
  sticky viewport chrome around captures.
- Preserve and display unmet steps when ignored acceptance scenarios do not
  reach their terminal expectations.

## v0.6.6

- Normalize absent screenshot metadata when importing unreached acceptance
  steps, allowing ignored scenarios to persist their unmet final expectations.

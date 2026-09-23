# AcceptanceHarness reference

## Scenario resource gates

Long-lived application scenarios can use
`AcceptanceHarness.ResourceGate.Collector` for platform-specific sampling and
pass the normalized final result to `AcceptanceHarness.ResourceGate.verify!/1`
during scenario teardown. The gate requires baseline, peak, and post-settle
memory, process survival, a sample count, an explicit retained-growth budget,
and a leak-check disposition. Optional handle baselines support Linux file
descriptors and macOS handles. Missing platform collection is reported as
`skipped` with a reason and never passes silently.

Collectors stay outside the core package so an iOS consumer can use
Instruments/jetsam evidence while a GNOME consumer uses `/proc` RSS and file
descriptor counts.

`AcceptanceHarness.ResourceGate.ProcessCollector` is the built-in local-process
adapter for GNOME clients, native macOS clients, and iOS Simulator apps. It
samples RSS with `ps`, records Linux file descriptors or macOS handles when
available, and fails if the process disappears. It deliberately returns
`{:skip, reason}` for physical iOS: a remote device PID is not a host PID and
must be measured by a compatible Instruments adapter.

Reusable acceptance-test harness for Phoenix applications.

Browser-driven consumers can use
`AcceptanceHarness.BrowserEvidence.page_content_script/0` when recording page
HTML. It snapshots loaded CSS rules into the cloned document so rendered
evidence remains styled after the original test server is gone.

For stable full-page screenshots, wrap the capture with
`AcceptanceHarness.BrowserEvidence.pin_viewport_chrome_script/0` and
`unpin_viewport_chrome_script/0`. Full-page captures paint `position: fixed`
and `sticky` elements at the current scroll offset, stranding site headers
mid-image; the pin script scrolls to the top and temporarily rewrites those
positions, and the unpin script restores them after the shot.

Chromium can rarely reject an otherwise valid capture with
`Page.captureScreenshot: Unable to capture screenshot`. Consumers should wrap
their driver call with the idempotent, narrowly targeted retry:

```elixir
AcceptanceHarness.BrowserScreenshot.capture(conn, screenshot_name, &screenshot/2)
```

It retries that specific protocol failure once and immediately re-raises every
other browser or assertion failure.

This package provides:

- Markdown evidence capture for acceptance scenarios.
- Static HTML evidence-site generation.
- ExUnit failure diagnostics insertion.
- Production gate checks from acceptance status and evidence.
- PhoenixTest/Playwright acceptance-mode helpers.
- Postgres created-row tracking for safe staging cleanup.
- Mix tasks for CI wrappers.

See [Specification best practices: integration blind spots](specification_best_practices.md)
for the interruption, deployment-composition, synchronization, and cross-surface
checks that static final-state scenarios frequently miss.

## Scenario isolation

Browser scenarios should use the harness case wrapper:

```elixir
use AcceptanceHarness.Playwright.Case, async: false
```

It delegates to `PhoenixTest.Playwright.Case`, which creates and closes a fresh
browser context for every test. That boundary isolates cookies, local/session
storage, IndexedDB, Cache Storage, service workers, permissions, pages, and
downloads between scenarios.

For browser scenarios that also record acceptance evidence, use the combined
case wrapper:

```elixir
use AcceptanceHarness.Playwright.ATDDCase, async: false
```

It composes the isolated Playwright case with the explicit evidence façade.
Non-browser producers can expose the same façade from an app-local module:

```elixir
defmodule MyApp.AtddEvidence do
  use AcceptanceHarness.EvidenceFacade
end
```

The façade delegates only the intentionally supported `AcceptanceHarness.Evidence`
functions; new harness functions are not exposed automatically.

If a single scenario deliberately changes actors, reset the existing context
before issuing the next login:

```elixir
conn =
  AcceptanceHarness.Playwright.switch_browser_identity(conn, fn conn ->
    MyAcceptanceHelpers.log_in(conn, next_user)
  end)
```

Application state remains the consumer's responsibility. Reset database
fixtures/sandboxes, captured mail, background jobs, mutable application config,
and process-global fakes in consumer setup hooks. Configure uploads and generated
files under unique per-run roots. Cleanup must target only harness-owned paths
identified by a sentinel or manifest; never erase a shared `tmp/` or application
upload directory.

`mix acceptance.schema_diagram` is silent for unchanged DOT/SVG artifacts. When
an artifact changes it prints a size summary and, for DOT sources, a capped
changed-line preview; generated SVG contents are never dumped into CI logs.

## Evidence surfaces and artifacts

Review presentation and evidence integrity are specified in
[the canonical review guide](approval_review_bundle_example.md) and the
[generated acceptance contract](../AGENTS.md). Keep those authoritative sources
rather than maintaining a second copy here.

## Terminal transport

The optional terminal transport launches arbitrary interactive programs in a
real pseudo-terminal. It emits raw output bytes and exposes normalized
fixed-grid snapshots backed by the maintained Rust `vt100` parser. Raw ANSI
remains the diagnostic source while snapshot text becomes `surface.text`.

Build the host-local helper once before terminal scenarios run:

```sh
mix acceptance.terminal.build
```

The build is pinned by `rust-toolchain.toml` and `native/pty_helper/Cargo.lock`.
It currently supports macOS and Linux. Consumers can then use the transport
directly or place their own screen driver above its behaviour:

```elixir
alias AcceptanceHarness.Terminal.PortTransport

{:ok, terminal} =
  PortTransport.start(
    command: ["./repo-toolbox", "tui"],
    rows: 24,
    cols: 80,
    cwd: "/path/to/fixture"
  )

receive do
  {:terminal_transport, ^terminal, {:output, raw_ansi_bytes}} ->
    raw_ansi_bytes
end

{:ok, screen} =
  AcceptanceHarness.Terminal.Screen.snapshot(PortTransport, terminal)

:ok =
  AcceptanceHarness.Terminal.Assertions.assert_visible!(
    screen,
    "Repository health"
  )

:ok = PortTransport.input(terminal, "r")
:ok = PortTransport.resize(terminal, 40, 120)
:ok = PortTransport.stop(terminal, :scenario_complete)
```

Each session is supervised and tied to its owner process. Owner exit, explicit
stop, and helper control-stream closure terminate and reap the child. Runtime
resize returns only after the native resize succeeds. The framed protocol keeps
output byte-for-byte intact while `vt100` incrementally handles split UTF-8,
styling, cursor movement, erase operations, scrolling, and alternate screens.
`AcceptanceHarness.Terminal.Evidence.record_step!/5` writes normalized `.txt`
and raw `.ansi` artifacts through the existing terminal evidence surface.

## Install

Use a pinned private Git dependency in consuming apps:

```elixir
{:acceptance_harness,
 git: "git@framagit.org:olivierg/acceptance_harness.git",
      tag: "v0.10.8"}
```

During local extraction from Agile-U, a path dependency can be used:

```elixir
{:acceptance_harness, path: "../acceptance_harness", only: :test}
```

## Configuration

```elixir
config :acceptance_harness, :harness,
  app_name: "My App",
  otp_app: :my_app,
  site_title: "My App ATDD Evidence",
  evidence_dir: "tmp/atdd",
  screenshot_dir: "tmp/atdd/screenshots",
  trace_dir: "tmp/atdd/traces",
  commit_sha_env: ["MY_APP_GIT_SHA", "CI_COMMIT_SHA"],
  scenario_title_aliases: %{}
```

### Public health endpoint

For a small, unauthenticated deployment liveness endpoint, configure the
consumer's OTP application and deployment environment prefix:

```elixir
config :acceptance_harness, :health,
  otp_app: :my_app,
  env_prefix: "MY_APP"
```

Import `AcceptanceHarnessWeb.Router` and mount the route in the application's
JSON/API pipeline:

```elixir
scope "/", MyAppWeb do
  pipe_through :api
  acceptance_harness_health("/health")
end
```

It returns only public deployment metadata: `status`, `version`, `release_id`,
`env`, `color`, numeric `age_seconds`, human-readable `age`, and opaque
`pipeline_id`. It deliberately does not add separate pipeline-URL, commit-SHA,
branch, or CI-credential fields. Keep dependency-backed readiness checks (for
example `/health/deep`) application-specific.

Applications should build deep readiness responses by extending the same
`AcceptanceHarness.Health.payload/0` map, so `/health` and `/health/deep` expose
identical deployment identity. Staging and production verifiers can enforce
that identity without changing local health behavior:

```elixir
:ok =
  AcceptanceHarness.Health.payload()
  |> AcceptanceHarness.Health.validate_deployed_identity!()
```

The validator requires nonblank, non-`"unknown"` `release_id` and
`pipeline_id`. It is opt-in because local and test servers commonly have no CI
deployment identity.

### Superadmin deployment versions

The same health configuration feeds a shared deployment-history page. Mount it
inside the host application's authenticated **superadmin** scope; the harness
deliberately relies on the host's authorization pipeline because user and role
representations are application-specific:

```elixir
config :acceptance_harness, :health,
  otp_app: :my_app,
  env_prefix: "MY_APP"

config :acceptance_harness, :deployment,
  history_path: "/var/lib/my_app/deployments.jsonl",
  peer_versions_url: "https://staging.example.org/admin/versions",
  peer_acceptance_url: "https://staging.example.org/admin/acceptance/",
  page_size: 10

config :acceptance_harness, :harness,
  admin_acceptance_path: "/admin/acceptance",
  admin_versions_path: "/admin/versions"

scope "/admin" do
  pipe_through [:browser, :require_authenticated_user, :require_superadmin_user]

  acceptance_harness("/acceptance")
  acceptance_harness_versions("/versions")
end
```

`/admin/versions` shows the running release followed by historical deployments
grouped by application version, with configurable pagination and
case-insensitive search across all recorded fields, including partial commit
hashes and commit messages. In production it also compares the running release
with the preceding production release. `peer_versions_url` optionally links
that release to the matching versions search in staging.
`peer_acceptance_url` adds a direct acceptance-results link to each deployment
card, filtered by pipeline, commit, or release identity. The built-in history
provider may also return rows with `version_only: true` and `committed_at`;
these render as version history rather than falsely claiming a deployment.
The default file provider reads newline-delimited JSON newest-first and ignores
malformed lines.
Applications may instead configure zero-arity functions or MFA tuples:

```elixir
config :acceptance_harness, :deployment,
  current_provider: {MyApp.Deployments, :current, []},
  history_provider: {MyApp.Deployments, :history, []}
```

The `admin_acceptance_path` and `admin_versions_path` settings enable reciprocal
links. Leave either unset when that sibling surface is not mounted.

When imported evidence includes CI pipeline metadata, each deployment card also
links to the corresponding live run and to its stored static report. Matching
prefers the exact pipeline ID and falls back to the exact commit SHA for evidence
imported before pipeline IDs were recorded. The static link is the run-specific
GitLab job artifact recorded as `source_url`; unlike a Pages URL, it remains tied
to that release, subject to the project's artifact-retention period.
Live screenshot routes prefer a screenshot available in the imported run's
local source directory and fall back to that stored artifact URL only when the
local file is unavailable.

### Local evidence retention

After evidence has been imported, applications can apply tiered local
screenshot retention without deleting database-backed run, scenario, step, or
review metadata:

```elixir
runs = AcceptanceHarness.AdminStore.retention_runs(repo: MyApp.Repo)

AcceptanceHarness.EvidenceRetention.apply(runs,
  root: "/var/lib/my_app/acceptance-evidence",
  max_bytes: 8 * 1_024 * 1_024 * 1_024,
  snapshot_prefix: "acceptance_evidence_",
  current_name: "current",
  in_progress_marker: ".in-progress",
  orphan_grace_seconds: 24 * 60 * 60,
  skip_unmanaged: true,
  prune_payload_names: ["evidence.json"]
)
```

By default, full screenshots are retained for every run for three days, then
for one run per UTC day through three weeks, per ISO week through three months,
and per calendar month through three years. Runs older than three years and
non-representative runs in every tier are archived by deleting their originals
only after a matching `thumbnails/<basename>.webp` has been verified. Generate
those small WebP files in CI so staging does not need image-processing tools.
Legacy runs without thumbnails retain their originals and are reported in
`archive_skipped`. An injectable thumbnail callback or the opt-in
`generate_missing_thumbnails: true` ImageMagick fallback is also available.

Once the screenshot cap is exceeded, the oldest retained representatives are
archived as needed, then thumbnails are removed oldest-first. Before sacrificing
referenced evidence, the same cap accounts for unreferenced snapshot directories
whose basename starts with the explicit `snapshot_prefix` and deletes the oldest
safe ones. A snapshot is never considered deletable during the grace period,
while it has the in-progress marker, or while it is the target of `current_name`.
The `current_name` entry itself is never touched. Snapshot symlinks and snapshots
containing symlinks are not followed or deleted.

The newest imported run is always protected. Size accounting includes originals
and thumbnails across referenced and protected orphan snapshots and is
inode-aware, so CI transport may hardlink unchanged screenshots without
double-counting them. The cap is best-effort: legacy runs without thumbnails,
the newest run, current/in-progress/recent snapshots, or unsafe filesystem
entries can leave `over_limit_bytes` above zero. Check `skipped`,
`archive_skipped`, and `orphan_skipped` when that occurs.

The evidence root is mandatory. Symlinked source, screenshot, or payload paths
are rejected. Payload cleanup is opt-in and uses explicit basenames; enable it
only after a successful import. Schedule one retention call at a time per
evidence root; calls within one BEAM node are serialized automatically.
Imported runs whose local directory has already gone are reported in `skipped`
and do not prevent maintenance of the remaining runs. Legacy paths outside the
managed root are also skipped by default; pass `skip_unmanaged: false` for
strict validation instead.

Orphan scanning is disabled unless `snapshot_prefix` is configured. Keep that
prefix specific to immutable evidence snapshot directories, and create the
in-progress marker before upload starts. Remove it only after the snapshot is
complete, imported, and eligible for later cleanup.

## Mix tasks

```sh
MIX_ENV=test mix ecto.setup
mix acceptance.site tmp/atdd public
mix acceptance.append_failures tmp/ci/atdd_test.log tmp/atdd/e2e.md tmp/atdd/failure_summary.txt
mix acceptance.append_failures tmp/ci/atdd_test.log tmp/atdd/e2e.md tmp/atdd/failure_count.txt tmp/atdd/failure_previews.json
mix acceptance.gate tmp/atdd/status.env tmp/atdd/e2e.md
mix acceptance.schema_diagram
```

Run `mix acceptance.update_agents` when installing or upgrading the harness in
a consumer. It adds `/tmp/` to the consumer's `.gitignore` when needed and
refuses to continue if Git already tracks files beneath `tmp/`; move durable,
approved evidence summaries to `docs/` first. Use
`mix acceptance.update_agents --check` in normal validation to enforce both
the guidance version and this repository hygiene policy.

`acceptance.schema_diagram` reads the migrated PostgreSQL schema and writes
`<output>.dot` plus `<output>.svg`. The SVG records the SHA-256 of its DOT
source. When that hash still matches, the task does not invoke Graphviz or
rewrite the SVG, so different installed Graphviz versions cannot create layout
churn during ordinary migrations and tests. A changed DOT source forces a new
SVG render. When the prior SVG reports another Graphviz version, the task emits
a warning that the resulting diff may contain broad layout-only changes.
Existing unstamped SVGs are rendered once to adopt this contract.
Tables with the most foreign-key relationships are rendered larger and more
prominently to make the diagram easier to orient.

Configure it once in the consuming application. Run it after migrations from
the application's normal development workflow, and keep the task available as
a standalone command when only diagrams need refreshing. Attaching it to an
`ecto.migrate` alias is appropriate when the application's test bootstrap does
not invoke that alias. When tests do invoke `ecto.migrate`, place it in
precommit or a separate migration-and-documentation alias instead, so unit
tests do not rewrite tracked documentation.

```elixir
# config/config.exs
config :acceptance_harness, :schema_diagram,
  repo: MyApp.Repo,
  output: "docs/schema/my_app_schema",
  schemas: ["public"]

# mix.exs
defp aliases do
  [
    precommit: [
      "ecto.create --quiet",
      "ecto.migrate --quiet",
      "acceptance.schema_diagram",
      # the application's remaining format, compile, and test checks
    ]
  ]
end
```

Command-line options (`--repo`, `--output`, and `--schemas public,reporting`)
override this configuration when needed. Generate from a dedicated clean
database when a long-lived local test database can retain abandoned migration
experiments. For an application whose test alias does *not* invoke the
`ecto.migrate` alias, the following alternative runs the diagram after each
normal migration:

```elixir
"ecto.migrate": ["ecto.migrate", "acceptance.schema_diagram"]
```

#### Suggested Git hook

The harness does not install or overwrite consumer Git hooks. A consumer using
the precommit placement can enforce diagram freshness with this `pre-commit`
pattern, adjusting the command and output directory to its own workflow:

```sh
#!/bin/sh
set -eu

scripts/mix-capped.sh precommit

# Generated files appear after Git has prepared the index. Stop so they can be
# reviewed and staged with the migration before retrying the commit.
if ! git diff --quiet -- docs/schema ||
    [ -n "$(git ls-files --others --exclude-standard -- docs/schema)" ]; then
  echo "Schema diagrams changed; review and stage docs/schema, then commit again." >&2
  exit 1
fi
```

A pre-push hook may repeat checks, but it cannot add freshly generated files to
the commit being pushed. Do not rely on a pre-push-only hook for tracked schema
artifacts.

### Domain diagrams

Set `domains_file` to an Elixir file returning a list of `%{id:, title:,
tables:}` maps and `domains_output` to generate a compact diagram per domain.
Each physical table must occur in exactly one domain. Use `optional_tables` for
tables that exist only in selected environments. A domain diagram keeps
foreign-key arrows: blue tables are local, while amber dashed arrows point to
solid amber external-table cards whose other relationships are intentionally
omitted.
Use one output path for backward-compatible behavior (legacy first-failure preview).
Provide both output paths for the new contract:
- `failure_count.txt` is just the failure count
- `failure_previews.json` is a capped list of failure preview objects (up to 5 entries)

## Ignored and skipped acceptance scenarios

Declare a scenario as `ignored` when it remains a desired acceptance contract
but a known product defect or incomplete capability prevents it from passing.
Declare it as `skipped` only when the scenario cannot be evaluated in the
current environment. Both require a reason:

```elixir
@scenarios [
  %{
    id: "solver-recovers",
    title: "Solver recovers from a misplaced piece",
    status: :ignored,
    reason: "The human-like backtracking strategy is incomplete"
  },
  %{
    id: "native-gesture",
    title: "Player uses the native platform gesture",
    status: :skipped,
    reason: "The CI browser does not expose this gesture"
  }
]
```

An ignored test must execute through `AcceptanceHarness.ignore/2` so its known
failure is captured without making ExUnit red:

```elixir
@tag :ignore
test "solver recovers", context do
  AcceptanceHarness.ignore(@solver_recovery_scenario, fn ->
    run_solver_recovery_scenario(context)
  end)
end
```

If the scenario completes and marks itself successful, evidence turns green so
the obsolete ignore can be removed. Use ExUnit's `@tag skip: "reason"` only for
a scenario declared `status: :skipped`; skipped scenarios do not execute.
The scenario registry preserves the acceptance meaning in evidence:

- `ignored` is orange and denotes accepted, visible product debt;
- `skipped` uses a black/white hatched treatment and denotes “not evaluated”;
- an undeclared scenario that does not run remains `not_run` and fails the
  acceptance gate.

The evidence gate accepts explicitly ignored and skipped scenarios when the
ExUnit run itself succeeds. It never treats either status as passed. Ignored
scenario exceptions and partial evidence remain visible in the report.

Call `AcceptanceHarness.Evidence.record_pending_step/4` immediately before an
ignored scenario attempts an expected endpoint. If the scenario fails first,
the report and structured scenario steps retain that expectation as a red
`(not reached)` step; if the normal capture occurs, it replaces the pending
entry with the successful evidence step.

## Database-backed tests

`mix test` runs all test suites when Postgres is available. For local first-time setup:

```sh
MIX_ENV=test mix deps.get
MIX_ENV=test mix ecto.setup
MIX_ENV=test mix test
```

By default, the harness looks for a local test database using:

- `ACCEPTANCE_HARNESS_TEST_DB_USER` (default: `postgres`)
- `ACCEPTANCE_HARNESS_TEST_DB_PASSWORD` (default: `postgres`)
- `ACCEPTANCE_HARNESS_TEST_DB_HOST` (default: `localhost`)
- `ACCEPTANCE_HARNESS_TEST_DB_NAME` (default: `acceptance_harness_test`)

## Phoenix consumer sample

`examples/phoenix_consumer` is a minimal Phoenix application that mounts the
admin acceptance routes, imports an evidence run into Postgres, and exercises
the redirect and LiveView route. It is the integration contract for consumer
applications and is run alongside the harness suite in CI.

Run it locally with a PostgreSQL server available:

```sh
cd examples/phoenix_consumer
mix deps.get
mix test
```

Run its isolated reviewer browser scenario with the locked Playwright client:

```sh
cd examples/phoenix_consumer
npm ci --prefix assets
PLAYWRIGHT_SKIP_BROWSER_GC=1 npx --prefix assets playwright install chromium
ACCEPTANCE_HARNESS_TEST_DB_USER=postgres \
  ACCEPTANCE_HARNESS_TEST_DB_PASSWORD=postgres MIX_ENV=test \
  MIX_TEST_PARTITION=reviewbaseline mix ecto.create
ACCEPTANCE_HARNESS_TEST_DB_USER=postgres \
  ACCEPTANCE_HARNESS_TEST_DB_PASSWORD=postgres MIX_TEST_PARTITION=reviewbaseline \
  ATDD=true ATDD_PORT=4117 \
  ATDD_ARTIFACT_ROOT=tmp/atdd/reviewer-current-evidence \
  mix test test/acceptance_harness_consumer/reviewer_current_evidence_atdd_test.exs \
  --include atdd --max-cases 1
```

The scenario binds only to localhost, uses a test-only reviewer session, and
writes sanitized PNG/HTML evidence beneath the explicitly harness-owned artifact
root.

## Safe staging cleanup

Avoid deleting test data by prefix or wiping staging databases. For Postgres
apps, install the DB tracker once, start a global ATDD run, and clean up the rows
inserted during that run:

```elixir
run_id = "atdd-#{System.system_time(:second)}"

AcceptanceHarness.DbTracker.install!(MyApp.Repo)
AcceptanceHarness.DbTracker.begin_run!(MyApp.Repo, run_id)

# seed and run acceptance scenarios; leave records in place for troubleshooting

AcceptanceHarness.DbTracker.end_run!(MyApp.Repo)

# before the next run with the same run id
AcceptanceHarness.DbTracker.cleanup!(MyApp.Repo, run_id, reset?: true)
```

Cleanup deletes exact primary-key rows in reverse insertion order.

## Admin review UI

The Phoenix admin surface at `/admin/acceptance/runs/:run_id` shows a screenshot
strip on every scenario card. Each thumbnail links to the matching step on the
scenario detail page and uses the scenario-local step number as its overlay. If a
scenario failure can be matched to a captured step or pending step, that
thumbnail is outlined in red. Scenario cards and the run list compare against
the previous run and show icon badges for `NEW` scenarios. `DELTA` scenarios are
based on scenario source checksums (`source_checksum`, `source_sha256`, or a
computed checksum from `source_path`/`source_file`) so browser evidence changes
do not create false source deltas. Finalized evidence also stores a
content-addressed source snapshot for each registered scenario file. When both
compared runs contain snapshots, the scenario page shows a colored,
context-limited line diff; older runs without snapshots retain the checksum
change notice. Recorded steps separately show exact title and description
changes so source changes are not falsely attributed to a particular step. The
run list links directly to each new or changed scenario.

For historical evidence imported without scenario source metadata, the admin
comparison falls back to the ordered step titles and descriptions. This makes
recorded contract additions and rewrites visible without treating changed
screenshots, URLs, durations, or other runtime evidence as scenario deltas.

When multiple scenarios share one Elixir file, identify the exact test block so
an edit marks only its owning scenario:

```elixir
%{
  id: "existing-player-joins-game",
  title: "Existing player joins the shared game",
  source_file: __ENV__.file,
  source_test: "owner and an existing player share a game"
}
```

`source_test` must exactly match one `test "..."` title in an `.ex` or `.exs`
file. The harness hashes and snapshots that original source block, including its
declaration and body, and fails setup when the locator is missing or ambiguous.
Scenario metadata may include `value_stream`, `capability`, and
`business_outcome`; the run page displays these fields, filters by stream and
capability, and includes the outcome in scenario search.

### Renaming scenario keys

When an application renames a scenario, keep its prior keys in the scenario
registry so previous-run comparison follows the same acceptance contract:

```elixir
%{
  id: "participants-01-register-for-session",
  title: "Participant registers for a public session",
  legacy_ids: ["sessions-facilitator-publishes-desktop"]
}
```

`AcceptanceHarness.Evidence` records `legacy_ids` in scenario metadata. An alias
may belong to only one current scenario and cannot also be another current
scenario key. Previous-run comparison follows aliases, so a rename is not
reported as a new scenario. Keep aliases until all environments have imported
the canonical scenario and any external evidence links have been updated.

## CI lifecycle

The intended CI lifecycle is:

```text
build release -> deploy staging -> acceptance evidence -> acceptance gate -> deploy production
```

The library owns evidence, diagnostics, and gate logic. Applications still own
their release build, staging seed/reset data, deploy implementation, and
product-specific scenarios.

## Stale local ATDD selection

Consumers may expose `mix test.atdd --stale` by calling the harness task from
their locked ATDD runner:

```sh
mix acceptance.stale_files select \
  --directory test/ecojeux_web/atdd \
  --evidence tmp/atdd/evidence.json \
  --manifest tmp/atdd-stale-files.json

# After a successful ordinary full run:
mix acceptance.stale_files record-all --directory test/ecojeux_web/atdd \
  --manifest tmp/atdd-stale-files.json

# After a successful stale run, pass exactly the selected paths:
mix acceptance.stale_files record-selected test/ecojeux_web/atdd/example_atdd_test.exs \
  --directory test/ecojeux_web/atdd --manifest tmp/atdd-stale-files.json
```

Selection is the union of scenarios marked failed in the last finalized
`tmp/atdd/evidence.json` and scenario files whose SHA-256 differs from the last
successful full or stale selection. Source hashes include uncommitted changes.
Missing, corrupt, incomplete, or incompatible evidence/manifest prints an
explicit `__FULL__` fallback marker. An empty selection prints nothing.

Scenario tags are the target vocabulary, not an automatic source-impact map.
Changed-path rules translate source files into those tags. Commit markers and
path mappings may add coverage only; an unmapped or ambiguous path selects the
full suite rather than silently narrowing it.

## Integration recipe

For a step-by-step handoff recipe, see
[docs/phoenix_acceptance_harness_recipe.md](phoenix_acceptance_harness_recipe.md).

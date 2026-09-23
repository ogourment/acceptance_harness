# Phoenix acceptance harness integration recipe

Use this recipe for recording evidence and mounting the authenticated reviewer.
For portable HTML/Markdown review, start with [standalone tools](standalone.md).
The example pins the 0.11.0 release, including cumulative review activity and portable tools.

## 1. Add the dependency

```elixir
defp deps do
  [
    {:acceptance_harness,
     git: "git@framagit.org:olivierg/acceptance_harness.git",
     tag: "v0.11.0"}
  ]
end
```

For Framagit CI, allow the consuming project to read `olivierg/acceptance_harness`, or provide a CI token through the dependency URL helper used by the app.

## 2. Configure the harness in `config/test.exs`

```elixir
config :acceptance_harness, :harness,
  app_name: "My App",
  otp_app: :my_app,
  site_title: "My App Acceptance Evidence",
  evidence_dir: "tmp/atdd",
  screenshot_dir: "tmp/atdd/screenshots",
  trace_dir: "tmp/atdd/traces",
  commit_sha_env: ["MY_APP_GIT_SHA", "CI_COMMIT_SHA"],
  scenario_title_aliases: %{}
```

Configure PhoenixTest/Playwright to use the same artifact paths:

```elixir
config :phoenix_test,
  otp_app: :my_app,
  base_url: System.get_env("ATDD_BASE_URL", "http://localhost:#{System.get_env("PORT", "4002")}"),
  playwright: [
    screenshot_dir: "tmp/atdd/screenshots",
    trace_dir: "tmp/atdd/traces",
    timeout: 5_000
  ]
```

## 3. Add the evidence façade

Keep the consumer namespace while avoiding a repeated list of delegates:

```elixir
defmodule MyAppWeb.AtddEvidence do
  use AcceptanceHarness.EvidenceFacade
end
```

For browser scenarios that record evidence, the combined case wrapper includes
the façade automatically:

```elixir
defmodule MyAppWeb.RegistrationATDDTest do
  use MyAppWeb.ConnCase
  use AcceptanceHarness.Playwright.ATDDCase, async: false
end
```

The façade exposes an explicit, curated subset of the current
`AcceptanceHarness.Evidence` API. New harness functions are not delegated
automatically. Use `AcceptanceHarness.Playwright.Case` directly when a browser
scenario does not need evidence helpers.

Expose object tracking through an app-local module too:

```elixir
defmodule MyApp.AtddCreatedObjects do
  defdelegate reset!(), to: AcceptanceHarness.CreatedObjects
  defdelegate record!(type, id, metadata \\ %{}), to: AcceptanceHarness.CreatedObjects
  defdelegate cleanup!(handlers, opts \\ []), to: AcceptanceHarness.CreatedObjects
end
```

For compatibility with existing script names, app modules can also delegate:

```elixir
defmodule MyApp.AtddSite do
  defdelegate build!(source_dir, public_dir), to: AcceptanceHarness.Site
end

defmodule MyApp.AtddFailureDiagnostics do
  defdelegate append!(log_path, report_path, summary_path \\ nil), to: AcceptanceHarness.FailureDiagnostics
end
```

## 4. Add Mix aliases

```elixir
defp aliases do
  [
    "test.atdd": ["cmd env ATDD=true mix test --only atdd --max-cases 1"]
  ]
end
```

Use `env` after `cmd`; otherwise recent Mix versions try to execute
`ATDD=true` as the program name.

For pointer-driven SVG grids, the harness provides a reusable Playwright
interaction that targets a logical row and column:

```elixir
AcceptanceHarness.Playwright.drag_to_grid_cell(
  conn,
  "#piece-123",
  row,
  col,
  board: ".puzzle-board"
)
```

The helper dispatches pointer events through the browser. It does not mutate
the DOM or application state directly.

Use `@tag :atdd` for acceptance scenarios and `@tag :slow` when they are browser-backed or staging-backed.

## 5. Start Playwright only for acceptance runs

In `test/test_helper.exs`, start Playwright supervision only when `ATDD=true`.

```elixir
if System.get_env("ATDD") == "true" do
  {:ok, _} = PhoenixTest.Playwright.Supervisor.start_link()
end
```

Preserve any app-specific setup required by PhoenixTest or Playwright.

### Install the Playwright browser once

The browser-driven scenarios need Playwright's Chromium binary, which is **not**
installed by `mix deps.get`/`npm install`. On a fresh dev box (and in CI images
that do not already bundle it) install it once — from the `assets/` directory,
where `playwright-core` lives:

```bash
cd assets && npx playwright install chromium chromium-headless-shell
```

Without it, `mix test.atdd` fails at `setup_all` with
`Executable doesn't exist at .../chrome-headless-shell` and every scenario is
reported as *invalid*. This is a harness prerequisite — document it here rather
than duplicating it in each consumer app's README.

## 6. Install ATDD authoring and worktree guidance

The harness installs a marked `AGENTS.md` block that treats evidence scenarios
as reviewer-owned product specifications. Agents must show current screenshots
and a detailed before/after scenario proposal, receive explicit approval before
editing the scenario, then show the resulting scenario diff and new screenshots
before committing or pushing. Approval of an application change does not by
itself authorize changing its acceptance contract.

Use one canonical tracked document at `docs/YYYY-MM-DD-topic.html`, refreshed
in place. Focus a scenario through an anchor in that document. The overview
and presentation use the same ordered items and review states. For a changed
visible state, keep clean before/after captures and show one native-width
side-by-side composite, with overlays outside immutable images. Do not invent
pairs for unchanged evidence. Follow the
[canonical review guide](approval_review_bundle_example.md) for the complete
presentation contract and [AGENTS.md](../AGENTS.md) for maintained agent rules.

The same managed block keeps ATDD safe in parallel worktrees.

ATDD starts a local Phoenix endpoint. A second worktree must use a distinct
port and matching Playwright base URL, or it can collide with another test
server. Configure the consumer's `config/test.exs` once:

```elixir
atdd_port = System.get_env("ATDD_PORT", "4002") |> String.to_integer()

config :my_app, MyAppWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: atdd_port],
  server: System.get_env("ATDD") == "true"

config :phoenix_test,
  base_url: System.get_env("ATDD_BASE_URL", "http://localhost:#{atdd_port}")
```

Then run ATDD in the additional worktree with, for example:

```sh
ATDD_PORT=4102 ATDD_BASE_URL=http://localhost:4102 mix test.atdd
```

Do not run two ATDD suites against the same test database at the same time.
After adding or updating the harness dependency, refresh the consumer's
instructions with:

```sh
mix acceptance.update_agents
```

This task owns only its marked section in the consumer's `AGENTS.md` and leaves
the rest of that file unchanged. Pass the consumer root explicitly when running
the task from the harness checkout: `mix acceptance.update_agents ../my_app`.
The managed guidance also documents the correct precommit placement for
checked-in schema diagrams when the consumer opts into
`mix acceptance.schema_diagram`. The [advanced reference](reference.md) includes a suggested
pre-commit hook pattern; do not rely on pre-push generation alone because it
cannot add newly generated artifacts to an already-created commit.

## 7. Structure scenarios for useful evidence

Each scenario should:

- Register a stable scenario id and human title.
- Capture key user-visible states with screenshots.
- Call `record_pending_step/4` immediately before assertions that may fail.
- Include metadata: `scenario_id`, `scenario`, `step`, `current_url`, `theme`, `device`, `viewport`, `language`, `click_target`, and `user` when relevant.
- Finalize evidence even when tests fail, through the CI template.

The pending-step call is important: if the assertion fails before the final screenshot, failure diagnostics can still show the expected step, current URL, device, language, click target, and matching screenshot.

## 8. Keep application state isolated

Do not rely on an `ATDD` prefix or database wipes for cleanup when staging may
also contain manual testing records. For Postgres-backed Phoenix apps, install
the DB tracker once and enable a global ATDD run id while setup and browser tests
execute:

```elixir
defmodule MyApp.Release.Atdd do
  def prepare_run!(run_id) do
    start_app!()
    AcceptanceHarness.DbTracker.install!(MyApp.Repo)
    AcceptanceHarness.DbTracker.cleanup!(MyApp.Repo, run_id, reset?: true)
    AcceptanceHarness.DbTracker.begin_run!(MyApp.Repo, run_id)
  end

  def finish_run!(run_id) do
    start_app!()
    AcceptanceHarness.DbTracker.end_run!(MyApp.Repo)
    retained_rows = length(AcceptanceHarness.DbTracker.created_rows(MyApp.Repo, run_id))
    %{retained_rows: retained_rows}
  end
end
```

The tracker creates `acceptance_harness_atdd_state` and
`acceptance_harness_created_rows`, then installs insert triggers on primary-key
tables in the configured schema. While a run id is active, inserts from seed code
and browser-driven HTTP requests are recorded globally. `finish_run!/1` should stop
tracking and leave those rows in place for troubleshooting. The next
`prepare_run!/1` call deletes rows recorded for the same run id before new seed
data is created.

This is intentionally staging-oriented. If another user creates records while
the ATDD run id is active, those records are also considered part of the ATDD run
and may be removed.

## 9. Keep external setup in the app in the app

The shared harness does not know how to seed product data. Keep these pieces in the consuming app:

- Release-side ATDD seed/reset module.
- Remote eval script or equivalent staging helper.
- Test users, organizations, fixtures, and external API-provider cleanup.
- Browser scenarios written in the product domain language.

External integrations that require stable IPs should run from staging through remote eval, not from GitLab runners.

## 10. Connect CI

Develop and review locally. Run affected ATDD once for matching source,
contract, dependencies and capability context. Deploy staging after bounded
build/startup/migration safety checks; run remaining full/deeper validation
thereafter, before production. Preserve the complete required gate. A local
fake cannot satisfy an external delivery assertion.

Shared CI owns reusable policy; each consumer declares its scenarios, mappings
and external boundaries. [Delivery and review activity](review-activity.md)
describes the phase order, receipt exchange and timing diagnostics. The inspected
consumer pipelines still need rollout; this guide does not claim that changing
guidance has changed their deployed CI.

## 11. Mount the authenticated reviewer

Mount the add-on inside the host application's authenticated browser scope:

```elixir
scope "/admin" do
  pipe_through [:browser, :require_superadmin]

  live_session :acceptance_harness_admin do
    AcceptanceHarnessWeb.Router.acceptance_harness("/acceptance")
  end
end
```

The mount provides:

- `GET /admin/acceptance` — run index LiveView.
- `GET /admin/acceptance/runs/:run_id` — run overview LiveView.
- `GET /admin/acceptance/runs/:run_id/scenarios/:scenario_id` — scenario LiveView.
- `GET /admin/acceptance/latest` — latest-run redirect.
- `GET /admin/acceptance/screenshots/:run_id/:filename` — screenshot delivery.
- `GET /admin/acceptance/artifacts/:run_id/*path` — supporting artifact delivery.

The 0.11 candidate also mounts GET/POST `/admin/acceptance/review-activity`.
Keep it under the same authentication, authorization and CSRF protection.
Configure `review_environment` and use [review activity](review-activity.md) for
counts and project-scoped receipt exchange.

The host owns session authentication, authorization, layout, LiveSocket setup,
and route placement. The harness supplies the controller and LiveView modules
and renders its scoped assets with those views.

### Storage and review activity

`AcceptanceHarness.AdminStore.install!/1` creates and maintains:

- `acceptance_harness_runs`
- `acceptance_harness_scenarios`
- `acceptance_harness_steps`
- `acceptance_harness_review_receipts` (0.11 candidate; independent lifetime)

Configure the host repository once or pass it explicitly:

```elixir
config :acceptance_harness, :harness, repo: MyApp.Repo
```

The main storage functions are:

- `AdminStore.import_evidence_data!/2`
- `AdminStore.list_runs/1`
- `AdminStore.list_scenarios/2`
- `AdminStore.list_steps/3`

An application upgrading from a version that stored review annotations or work
statuses must export and reconcile that history first, then use its own forward
migration to drop both retired tables. `install!/1` installs only the current evidence schema and drops the retired
status table; it is not a substitute for the application migration that retires
old comments after preservation.

### Renaming durable scenario keys

When an application renames a scenario, retain its earlier keys in the scenario
registry:

```elixir
%{
  id: "participants-01-register-for-session",
  title: "Participant registers for a public session",
  legacy_ids: ["sessions-facilitator-publishes-desktop"]
}
```

Evidence records those aliases in scenario metadata. An alias may belong to
only one current scenario and cannot also be another current scenario key.
Previous-run comparison follows aliases so a rename is not reported as new.

### Evidence retention

Raw per-step page HTML is the largest stored payload and has a bounded
retention window. `AdminStore.prune_step_html!/1` clears only eligible
`page_html`; it preserves run/scenario/step metadata, searchable `page_text`,
artifacts, and screenshots.

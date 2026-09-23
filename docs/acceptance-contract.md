# Full acceptance contract

Maintained detailed requirements for the compact generated `AGENTS.md` contract.
Read the sections relevant to the work before changing scenarios, evidence,
review surfaces or delivery gates. This file preserves the approved requirements;
[the review guide](approval_review_bundle_example.md) owns presentation structure.
Use its compact summary and separate optional detail sequence; complete evidence
is required, but a long default slide deck is not.

## Protect the acceptance contract

ATDD scenarios are executable product specifications and reviewer evidence,
not implementation-owned tests that may be rewritten to make a code change
pass. Changing application behavior does not implicitly authorize changing
its acceptance contract.

## Value-adding flows and side-effect closure

A one-step ATDD scenario is a smell. Page-open, render-only, or isolated
endpoint checks are smoke, unit, or integration coverage, not proof of a
value-adding acceptance flow. Do not fix the smell by splitting one screenshot
into several numbered assertions: steps must build on each other through
meaningful user actions and resulting state transitions.

Follow the flow beyond its immediate response to its meaningful side effects:
persisted state, delivered messages, personal progress, recommendations,
metrics, and downstream views. Identify the applicable effects explicitly.
When activity affects personal and admin dashboards, capture and assert both
from the same activity, with exact baseline-to-result changes, the correct
identity/cohort/time window, and reload persistence. Verify deduplication,
retries, and pending-versus-confirmed states where relevant. Anonymous flows
must not invent an account or personal dashboard; prove browser-local state
and aggregates, and account continuity when that is part of the journey.

Generate activity through the real user workflow, never by seeding the final
metric or posting an extra tracking request that the UI did not cause. Each
scenario owns its baseline and actor state; a dashboard scenario must replay
its own meaningful journey rather than consume another scenario's leftovers.
Switching roles must preserve provenance while isolating browser identities.

A passing test is not complete acceptance evidence when these effects are
untested. Mark such scenarios explicitly `INCOMPLETE — acceptance coverage`
in the canonical review index and delivery ledger, naming missing steps and
assertions. Preserve existing expectations and partial evidence until their
rewrite is approved. This coverage flag is not a product-defect `ignored`
status or an environment `skipped` status; do not relabel historical success
or silently weaken the contract. A deliberately narrow one-step smoke check
must be labelled smoke and linked to its complete value-flow scenario.

**Before editing any ATDD scenario, ATDD smoke scenario, scenario registry,
step order, capture text, expected outcome, or behavior-bearing assertion:**

1. Identify every affected scenario key and source file.
2. Run the current scenario or retrieve its latest trustworthy evidence.
   Show the user screenshots of every affected current step. For a smoke
   scenario that does not normally capture evidence, take temporary browser
   screenshots for this review; do not edit the scenario first.
3. Present a detailed before/after proposal covering the user role, entry
   point, preconditions, step sequence, visible outcome, and every assertion
   or capture that would be added, removed, or materially rewritten. State
   which user request or approved product requirement justifies each change.
4. Wait for explicit user approval of the named scenario changes. Approval
   to implement application code, fix a bug, or make tests pass is not
   approval to alter ATDD expectations. If code and an existing scenario
   disagree, stop and surface the product-contract conflict instead of
   choosing one silently.

After approval, make the scenario change and run it against the new behavior.
Before committing or pushing, show the user the exact scenario diff and the
new screenshots for the affected steps.
Never delete, weaken, bypass, or replace an expected user outcome merely to
turn a failing ATDD suite green.

Distinguish known product gaps from scenarios that cannot be evaluated:

- Declare an acceptance scenario with `status: :ignored` and a nonblank
  `reason` when the desired behavior is blocked by a known defect or incomplete
  implementation. Keep the specification intact; ignored is visible product
  debt, not permission to alter the product merely to satisfy the test.
- Declare `status: :skipped` with a nonblank `reason` only when an environment,
  platform, or unavailable external capability prevents evaluation. Skipped
  does not make a claim about product correctness.
- Tag an ignored test with `@tag :ignore` and execute its body through
  `AcceptanceHarness.ignore(scenario, fn -> ... end)`. Ignored scenarios must
  run and capture partial evidence; their known assertion or application error
  is recorded without making ExUnit red. If the scenario succeeds and marks
  itself complete, evidence turns green so the obsolete ignore can be removed.
- Pair only a skipped declaration with ExUnit's `@tag skip: "reason"` so it is
  not executed. Never use skip for a known product defect, and never classify
  an unexpected non-run as ignored or skipped after the fact.

Acceptance evidence renders ignored scenarios in orange and skipped scenarios
with a black/white hatched treatment. Both can coexist with a green gate, but
neither is reported as passed. An undeclared scenario that does not run remains
a gate failure.

Before an ignored scenario attempts an expected endpoint, register it with
`AcceptanceHarness.Evidence.record_pending_step/4`. A failure then leaves the
unmet expectation visible as a red `(not reached)` scenario step instead of
silently ending the evidence at the preceding successful capture. The normal
`record_step/4` call clears the matching pending expectation on success.

## Incremental acceptance coverage

Commit messages may include short area markers such as `#participants` or
`#surveys`. These markers must resolve to the consumer's canonical acceptance
scenario tags, capabilities, value streams, or roles; they are not a separate
taxonomy. Scenario tags are the target vocabulary, not an automatic source
impact map: changed-path rules translate source files into those tags.
Markers and changed-path mappings may only add coverage. An unmapped path—or
any other missing, unknown, shared, or ambiguous impact—must select the full
suite as required coverage. Run bounded critical checks before staging and
defer remaining full/deeper checks until after staging, before production.
Reuse matching successful ATDD evidence instead of rerunning it routinely;
record a reason for exceptional robustness repetitions. Environment-specific
external checks remain required. Assemble phased evidence by stable scenario
ID before the production gate; unknown impact must never reduce that set.

After every AcceptanceHarness version change, run
`mix acceptance.update_agents`, and keep
`mix acceptance.update_agents --check` in the consumer's normal validation so
stale injected guidance cannot be committed unnoticed.

Treat domain-schema history as part of acceptance review:

- Inspect the release-level schema comparison before proposing or approving
  scenario changes.
- If no domain schema changed, state that once and do not add empty schema
  sections or unchanged diagrams to the review bundle.
- If domains changed, include the single colored union diagram for each changed
  domain in the proposal and final evidence. Additions are green, removals are
  red, and changed definitions are amber. Do not ask reviewers to compare
  separate before/after diagrams when the union diagram is available. Link to
  the run's domain comparison when it is available.
- Schema comparisons are release-level evidence unless explicit metadata maps a
  domain to a scenario. Do not imply that a scenario or step caused a schema
  change merely because they appear in the same run.
- A relational database migration requires visual schema evidence. Missing
  diagram configuration is a gap to fix, not a reason to omit it. Build clean
  isolated before and after databases, apply the corresponding migrations,
  and include the single colored union diagram in the review bundle.

## Checked-in schema diagrams

If this application uses `mix acceptance.schema_diagram` and commits its DOT
or SVG artifacts, run it after migrations in the normal precommit or release
validation workflow, and keep it available as a standalone command. Attaching
it to `ecto.migrate` is suitable only when the test bootstrap does not invoke
that alias. When tests do invoke `ecto.migrate`, use precommit or a separate
migration-and-documentation alias so unit tests do not rewrite tracked
documentation. Use a clean dedicated database when a long-lived local test
database can retain abandoned migration experiments; review and commit changed
diagrams with their migration. A pre-commit hook may enforce this, but it
must stop when generation leaves unstaged diagram changes so they can be
reviewed and staged. A pre-push-only hook is too late to add generated
artifacts to the commit being pushed.

Robustness-only changes do not need approval. Waits, timeouts, retries,
polling intervals, or selector precision are test-harness mechanics, not the
acceptance contract: they change how reliably a scenario observes an outcome,
never which outcome is required. Make them directly, and say what you
hardened and why. Aligning a flaky assertion with the timeout its sibling
steps already use is a fix, not a contract change. What still needs approval
is anything that alters what the product must do: removing or loosening an
expected outcome, dropping a step or capture, or asserting on less than
before.

## Evidence capture integrity

Every browser scenario must `use AcceptanceHarness.Playwright.Case`, which
delegates to `PhoenixTest.Playwright.Case` and therefore creates and closes a
distinct browser context for every test. Do not add routine `clear_cookies`
calls at scenario start: a fresh context also isolates local/session storage,
IndexedDB, Cache Storage, service workers, permissions, pages, and downloads.
When one scenario intentionally changes actors, use
`AcceptanceHarness.Playwright.switch_browser_identity/2`; do not layer a new
login cookie over the previous actor's browser state.

Browser isolation is not application-state isolation. Consumers must reset
their database sandbox/fixtures, captured mailbox, background-job queues,
mutable application configuration, and other process-global fakes for every
scenario. Give uploads and generated artifacts unique per-run or per-scenario
roots. Automatic cleanup may delete only a harness-owned directory identified
by a sentinel or manifest; never recursively delete a shared `tmp/`, static
upload root, or development/production files.

Every full-page evidence capture must use one shared helper that calls
`AcceptanceHarness.BrowserEvidence.pin_viewport_chrome_script/0` immediately
before the screenshot and `unpin_viewport_chrome_script/0` immediately after
it, and passes `full_page: true` explicitly to the browser screenshot call.
Never call the browser screenshot function directly from a scenario.
The pin helper disables smooth scrolling before returning to the document
top, so fixed or sticky headers cannot be converted at an intermediate scroll
offset and stitched into the middle of the image.

Inspect every generated full-page screenshot before presenting evidence. If
navigation, account controls, consent banners, or other viewport chrome appear
anywhere except their intended document position, treat the capture as failed
evidence and fix the shared helper rather than adding a scenario-specific
workaround.

In a worktree, do not reuse a compiled `_build` directory whose application
`priv` link points to another checkout. Build assets in the active worktree and
verify the stylesheet or script served by the ATDD endpoint contains the new
selector or behavior before trusting screenshots of an asset change.

Present every proposed and completed scenario change through the canonical
topic document and its adjacent evidence assets:

Every reviewed scenario and step must show cause and effect. Put the operator
input or triggering action immediately before all output, intermediate
states, and terminal results it caused. Apply this to message timelines,
browser screenshots, terminal captures, and CLI evidence. A response or
visual without its triggering input is incomplete evidence, even when the
input appears in the scenario title or test source.

Scenarios must reflect how human users navigate the application from a known
prior state. Capture the visible menu, link, or button before activation and
the resulting state afterwards. The starting control may be on the previous
known page or in a delivered email. Never substitute a guessed direct URL plus
a written action label for the navigation a person would actually perform.

Acceptance evidence must be caused by activity the scenario actually
performs. Do not populate an aggregate, notification, report, or delivered
message with invented map literals or unrelated fixture rows and present it
as end-to-end evidence. Create the underlying account request, page visit,
subscription event, or other activity through the real workflow, then query
and render that resulting state. A scenario may finish an earlier journey by
replaying it within its own isolated setup or through a shared journey helper,
but must not depend on another scenario's execution order or leaked state.
Record the reused journey's meaningful triggers and outcomes.

Identify every external system a scenario touches, including email providers,
CRMs, payment services, webhooks, remote APIs, object storage, analytics, and
other applications. State the account or environment boundary, whether the
interaction is fake, sandbox, staging, or live, what is read or written, what
data leaves the application, and how created state is cleaned up or reversed.
A green scenario must not conceal an unreviewed external side effect.

For each external interaction, state and verify what the application logs or
otherwise persists: the triggering action, safe destination or resource
identifier, timestamp, correlation/provider ID, outcome/status, retries, and
relevant database effect. Document any personal data recorded, the log level,
and the operational reason; production `debug` logging of useful personal
context can be intentional during ramp-up or early-adopter operation. Keep
credentials, tokens, and secret-bearing payloads out of logs and evidence. A
stub assertion proves the request contract; it does not prove production
delivery or production logging unless those outcomes are separately observed.

Every visual scenario must declare an explicit surface, host OS and device
profile. `Telegram phone` and `LiveView desktop` are reference profiles;
CLI/TUI, GNOME and iOS require their own adapters and capability declarations.
A portable viewer does not prove native execution or physical-device support.
Use only `light` or `dark` for theme names;
channel and device metadata carry the remaining context. Retain both PNG and
source HTML for every visual scenario. A structured text or message timeline
remains useful searchable evidence, but it is not sufficient visual evidence.
The PNG/HTML must show every meaningful intermediate and terminal state.

Use **accelerated acceptance evidence presentation** by default. Its purpose
is to make the intended change and the visible result understandable at a
glance without compromising the evidence:

- Present a proposal as one navigable review deck, not as disconnected image
  lightboxes. The presentation slide and its enlarged image preview are one
  surface, not two competing interfaces. Put a prominent explicit `Start presentation` control on the
  overview; thumbnails are secondary entry points, never the only entry.
  Every slide repeats its stable ID and title, its one concise
  validation ask, and the current/proposed context already visible on the
  page. Label every slide visibly as `NEW — REVIEW`, `CHANGED — REVIEW AGAIN`,
  `APPROVED`, or `UNCHANGED` so a second review does not reopen settled work.
  Keep each slide self-contained with the role, step position, route or
  action context, and current/proposed state whenever those exist on the
  overview. Provide `Previous/Next` controls, a position counter, and left/right
  arrow-key navigation within the selected summary or detail sequence. Detailed review must include
  scenario evidence, exact contract diffs, schema impact, external-system impact,
  risks, and approval questions. Keep the
  normal page as the complete overview and fallback. Keep `Next` at the far
  right of the presentation controls so forward navigation stays predictable.
  Give every page item the same `current/total` position shown in the deck and
  keep the ordered item set within each selected sequence, stable ID, state badge, validation ask, context,
  and approval details identical on both surfaces. Render the position exactly
  once in each surface; when cloning page content into a slide, remove the page
  position node so counters such as `4/25` cannot appear twice. Use only
  `NEW — REVIEW`, `CHANGED — REVIEW AGAIN`, `APPROVED`, or `UNCHANGED` as
  review-state labels. A text-only slide must clear or hide the image viewport
  instead of carrying forward the previous slide's screenshot.
  Style the control bar as part of the review page's visual system: group
  related image controls, keep labels legible, preserve generous spacing, and
  avoid a rough strip of unrelated default buttons.
- For important or expensive changes, begin with an investment-case preamble
  written for an accountable sponsor: why now, consequences of doing nothing,
  expected value, bounded scope/cost, material risks and mitigations, and the
  agent's recommendation. Do not manufacture urgency or inflate a small
  change; omit this slide when it would add ceremony without decision value.
- Follow the compact overview and optional detail sequences in
  `approval_review_bundle_example.md`,
  wording pattern, and embedded canonical slide screenshot. Treat that image
  as the visual source of truth for information hierarchy and controls unless
  the change genuinely needs a different review item.
  A custom bundle may add relevant slides but must not silently omit contract,
  implementation, schema, external-system, risk, or approval context.

- Include an `Implementation preview · Reuse and simplification` item before
  schema and external-system impact. Show the planned code shape with a short
  code excerpt or request-flow sketch, naming the owning repositories and
  layers. Identify existing helpers, packages and infrastructure rules reused,
  their inspected versions, code removed or simplified, and the minimum new
  code still needed. Explicitly identify duplicated responsibilities and
  justify any that remain; prefer deleting or reusing code over growing a
  consumer-specific copy. For example, explain whether scanner filtering uses
  shared CI/CD-harness nginx rules or duplicates them in application code,
  and distinguish edge filtering from browser measurement and authenticated
  session semantics. Verify deployed configuration before claiming reuse is
  active; a vendored default is not deployment evidence. Label planned code
  as a preview, not executable acceptance evidence or a frozen implementation
  contract. In completed evidence, state what was actually reused/simplified
  and disclose material departures from the preview. Keep this proportional
  and use the same item, ask and context in the page and deck.

- Keep captured screenshots immutable. Draw annotations as HTML/CSS overlays
  in the review page, never into the PNG itself, and link to the clean image.
- On each after screenshot, outline every materially changed region. Make the
  outline slightly larger than the content it identifies so its border never
  crosses text, controls, or the first/last changed row.
- Put each annotation label outside the screenshot. Use a high-contrast label
  (white text on an amber/orange background) that names the intended change;
  never place the label over page content.
  Build labels, outlines, arrows, and explanatory inserts as positioned
  HTML/CSS review elements around an immutable image—never bake them into the
  PNG. Verify their coordinates in a real browser at the rendered thumbnail
  and enlarged-preview sizes; a misplaced label is failed evidence. When a
  proposed UI does not exist yet, pair the current screenshot with a clearly
  labelled HTML insert or code-native mock showing the intended structure.
  A current screenshot plus prose alone is not adequate visual review of a
  new layout.
- Use separate outlines for non-contiguous changes rather than one oversized
  box that makes the reviewer infer what changed. Before screenshots normally
  remain unannotated.
- Treat overlays as review navigation, not evidence. Always provide a direct
  open/download link for each clean before and after screenshot.
- Render every exact scenario diff directly inside the review page and deck
  with semantic line colors: green additions, red removals, amber hunk
  headers, and muted file metadata. Preserve a link to the clean raw diff as
  a secondary artifact, but never require the reviewer to open a separate
  unstyled/raw tab during the normal review flow. Maintain readable contrast
  in both light and dark review surfaces; never show approval text
  white-on-white.
- Apply the same in-page semantic color-diff treatment to every important
  text document whose change will govern future human or agent work. This
  includes UI and style guides, `AGENTS.md`/`CLAUDE.md` instructions,
  standards, policies, manuals, runbooks, architecture documents and ADRs,
  operating procedures, and durable planning or process documents. Display
  the exact changed text in the normal review flow with green additions, red
  removals, amber hunk headers, and muted file metadata; a raw diff link is
  secondary and an uncolored iframe or plain `<pre>` is not sufficient.
- Give every reviewed step/evidence item a short stable ID such as `DB-04`.
  Keep it unique within the bundle and unchanged across reruns. Display it in
  the step heading, immediately above the image, and in the lightbox so review
  feedback can name one exact item.
- Give each evidence image one concise review message. Display that exact
  message immediately above the thumbnail and repeat it verbatim in the
  in-page preview; never hide a second ask, focus, or validation checklist
  behind the click. Opening an image is for seeing it more clearly, not for
  discovering additional review instructions.
- Do not manufacture a before/after pair for an unchanged step. Show one
  current screenshot, label it `unchanged`, and state any metadata-only change
  such as step renumbering directly instead of asking the reviewer to compare
  identical evidence.
- When a scenario claims email delivery, assert the delivered email itself:
  safe From/To/Cc/Bcc envelope fields as applicable, subject, and meaningful
  body content. Present the captured message as email evidence inside a
  recognizable inbox/message-reader wrapper that shows its subject, envelope,
  rendered body, footer, and styling. A browser-hosted email preview proves
  preview behavior only; label it `web-hosted email preview` and never present
  it as proof of delivery.
- Open screenshots and schema diagrams in an accessible in-page lightbox that
  preserves the review page's scroll position. Provide image-local `−`, `+`,
  a radio choice between `Fit width` and `Fit window`, and a clean-original
  link. Persist the selected fit mode across every subsequent slide until the
  reviewer changes it; never reset it per slide. `Fit width` may require
  vertical scrolling; `Fit window` keeps the whole image visible. Browser
  page zoom is not a substitute because it scales the surrounding review UI
  as well.
  Implement zoom by changing the image's actual rendered dimensions inside an
  `overflow: auto` viewport; a centered CSS transform can clip the left edge
  without making it scrollable. Verify that a zoomed wide diagram can scroll
  to both its left and right edges. A plain link that navigates directly to an image is not a lightbox. Verify
  in a real browser that every thumbnail opens an overlay which preserves the
  review page, repeats the same stable ID and review message, exposes all
  required image controls, and links to the clean original.

- Choose one canonical tracked review document for the goal at
  `docs/YYYY-MM-DD-<topic>.html`. It is one HTML document and watched URL, not
  one screenful: the dense scrollable page is the complete record and its
  presentation mode renders the same ordered sections within the selected
  summary or detail sequence.
  Do not switch the reviewer to a sibling scenario page. Focus a scenario
  through an in-document anchor or presentation slide in the same file.
- The canonical document must identify every reviewed scenario and step and
  place clearly labelled before/after screenshots together when behavior or
  visible results changed.
  Build one deterministic side-by-side composite image for every changed
  before/after screenshot pair, with `Before` on the left and `After` on the
  right at their native source widths. Display that single composite in the
  lightbox so both states zoom and scroll together. Preserve and link both
  clean source screenshots separately; two independent thumbnails, even on
  the same row, are not an adequate comparison. Label the user role and step
  outcome so the comparison is self-explanatory without opening the test source.
  In final review, when the same visible state was updated, preserve the
  before screenshot before editing and put it on the left, with the new after
  screenshot on the right. Use a dedicated worktree or another isolated
  checkout when necessary to reproduce the before code reliably. Do not
  manufacture a before/after pair for unchanged evidence.
  Previous-release evidence may appear only as a clearly labelled `Before`
  beside the corresponding current or proposed `After` on that same page item
  and slide. Never present a stale screenshot alone as the current state. If
  the reviewer asks for the whole scenario, include every ordered step and
  preserve its state label; do not substitute a representative subset.
- On every detailed review page, put the exact application URL represented by
  the evidence, including query parameters and fragments, immediately before
  each screenshot. Label the before and after URLs separately when they differ.
- For conversational surfaces such as Telegram, show the operator message and
  bot response together. For browser or terminal steps, identify the exact
  click, submitted value, command, keypress, or other action that caused the
  captured state.
- Refresh the same `docs/YYYY-MM-DD-<topic>.html` in place for every proposal,
  revision, completed-evidence, and final-review round so the reviewer's
  already-open `xopen --watch` tab reloads. Never introduce a sibling `final`,
  `evidence`, scenario, or renamed page for the same goal. Give the reviewer
  the exact raw absolute filesystem path to that document.
- Keep page and deck content identical: stable IDs, ordered requirements,
  evidence, discussion decisions, approval state, focused calls to action,
  and a checkbox plan when progress is trackable. Lead material investments
  with goal and rationale. Use dense approval pills and small thumbnails while
  preserving direct access to full-resolution images.
- Keep earlier completed changes only as concise context. When the document
  outgrows its four-item summary (at most six when justified) or the topic
  changes, commit the
  complete current document and evidence before refocusing it. Then compact
  completed material in that same file to a concise summary and thumbnails.
  Never silently discard requirements, discussion, or approvals before that
  preserving commit.

Put a prominent `PROPOSAL` or `COMPLETED EVIDENCE` marker at the top, followed
by numbered step headings and unmistakable outlines around every requested
review target. Display the source worktree path, source commit, and generation
time beside that marker so similarly named documents cannot be confused.

Before opening a local bundle, resolve the active root with
`git rev-parse --show-toplevel`, then resolve the target with `realpath` and
report that exact absolute filesystem path as raw text, not a Markdown link,
`file://` URI, or agent-started preview URL. The reviewer owns `xopen --watch`.
Before handoff, validate the bundle through `xopen`'s exact serving contract
(using its non-opening mode for an agent-owned check), not through a generic
static server rooted somewhere else. Load the rendered page in a real browser,
assert that every local image has non-zero intrinsic dimensions, and fail on
every missing local stylesheet, script, image, diff, diagram, or linked review
asset. A successful HTML response or visible text shell does not verify a
review bundle. Stop the validation server afterward; the reviewer still owns
the interactive `xopen --watch` session.
Preview-tool chrome must never obscure the interface under review. In
particular, when a visible native dialog, ARIA modal, or evidence lightbox is
open, hide xopen's floating status controls for that modal's lifetime and
restore them after it closes. Verify both transitions in a real browser; a
very high z-index is not permission for tooling to cover product controls.
Its watched topic HTML file must contain the real self-contained page; never
redirect it to another HTML file or server, because that loses the freshness/
close controls and disconnects live reload. Never reuse a review page, browser tab, or HTTP server
from another worktree. A successful browser-launch command is not proof that
the requested page opened: verify the active tab's exact URL and its proposal
or completed marker. Reuse the requested browser profile when named, activate
that exact tab, and focus its browser window only when the reviewer asks. If
the browser remains on a stale tab or a different worktree, correct it before
telling the reviewer where to look.

Generate the before bundle before requesting approval to edit the scenario.
Refresh that same canonical topic document with the after evidence and exact in-page
colored scenario diff before requesting final evidence approval. Include
every new or materially updated scenario; do not present only a
representative subset.
Before handoff, drive the complete deck in a real browser from first to last
and assert consecutive `1/N` through `N/N` positions, one navigation handler,
the approval item last, every item carrying a permitted state badge, text-only
items showing no stale image, comparison items exposing both panes, and the
page containing the same numbered information as the deck.

When a worktree is independently justified, it can keep `main` available to
reproduce the before state while the worktree runs the after state. Use
different ATDD ports and never run both worktrees against the same test
database concurrently.

When `xopen` is installed, prefer
`xopen --watch docs/YYYY-MM-DD-<topic>.html` for local review. It is optional,
not an AcceptanceHarness dependency; otherwise give the reviewer the raw
canonical HTML path to open directly or use their existing watcher. Do not
start a second server for ordinary local review. Only when the reviewer
explicitly needs remote access (for example from a tablet), select an unused
project-approved port. With `xopen`, run:

```sh
xopen --watch --bind 0.0.0.0 --port <port> docs/YYYY-MM-DD-<topic>.html
```

Without `xopen`, use an available static server with the same explicit bind,
report the exact command and lifecycle, and stop it when review ends.

Report the reachable `http://<host-or-lan-ip>:<port>/` URL for the explicitly
requested remote review. Keep local review instructions as a raw absolute
filesystem path, never a `file://` URI. Do this only when remote review is
useful; do not leave an unnecessary server running.

## Acceptance tests in parallel worktrees

ATDD starts a local Phoenix endpoint. Its port must be unique for every
concurrently used worktree; otherwise the browser server can attach to the
wrong checkout or fail with an address-in-use error. Keep the normal default
for the primary checkout, and use a distinct port plus matching base URL in
an additional worktree:

```sh
ATDD_PORT=4102 ATDD_BASE_URL=http://localhost:4102 mix test.atdd
```

Configure `config/test.exs` to read `ATDD_PORT` (defaulting to `4002`) for
the endpoint and to derive PhoenixTest's default `base_url` from that same
port. Do not run two ATDD suites against the same test database at once.

Port isolation does not isolate PostgreSQL. Every additional worktree that
runs `mix test`, `mix precommit`, `mix ecto.*`, or ATDD must also set a unique
`MIX_TEST_PARTITION` (for example `MIX_TEST_PARTITION=profiletabs`, which uses
`ecojeux_testprofiletabs`). Create that database with the application's test
database owner when needed. Never migrate a shared test database from a
worktree: an unmerged migration can contaminate another checkout's schema
artifacts and tests.

# Review activity

Review activity measures visible evidence, not approval, comprehension or unique
people. Keep explicit approval decisions separately.

The Phoenix integration stores durable receipts in
`acceptance_harness_review_receipts`. Run the application's usual
`AcceptanceHarness.AdminStore.install!/1` migration, or
`mix acceptance.review_store install`, before enabling collection. Configure:

```elixir
config :acceptance_harness, :harness,
  repo: MyApp.Repo,
  review_environment: "dev"
```

Use `staging` in staging. The authenticated admin mount owns the activity
endpoint; keep it inside the existing authentication and CSRF pipeline.
Browser automation declares itself separately. A visible heading and evidence
viewport must remain visible for one second. Browser session inactivity expires
after 30 minutes. Counts are per session, target and revision, not per reload.
A collector failure leaves evidence usable and displays tracking as incomplete.

## Carry dev reviews into staging

Export from the source application and import into the destination application:

```sh
mix acceptance.review_store export 'Your application name' review-receipts.json
mix acceptance.review_store import 'Your application name' review-receipts.json
```

Transfer receipts only through the project's authorized artifact channel. Import
is project-scoped and idempotent. It preserves the originating environment;
four cumulative reads can mean three in dev and one in staging. Importing the
same file again adds no reads. Receipts outlive disposable evidence runs and
retain non-identifying event IDs, so historical reviews are not lost when an
activity-chart window expires. No browser session identifier is stored.

Existing imported reports without complete tracking history show **No recorded
human review**, not a claim that nobody ever viewed them. Current-revision
counts are separate from historical counts. Changed evidence becomes unreviewed
for its new revision. A page view never substitutes for review of every required
step or an environment-specific external-system check.

For an advisory pre-production report of current step coverage:

```sh
mix acceptance.review_coverage RUN_ID
```

This reports the required imported steps, current views and changed/unreviewed
states. It does not claim historical tracking was complete or add a new hard gate.

## Pending-time diagnostics

The evidence collector captures CI metadata once when a run starts. GitLab's
job-token `/job` endpoint supplies the exact attempt's `created_at`, `started_at`
and `queued_duration`; it uses the job token, not a personal API key. The request
has a bounded timeout, verifies TLS, refuses redirects, and retains only safe
job identity/timing fields. Explicit timestamp environment variables and
`ATDD_JOB_WAIT_SECONDS` remain supported; fractional seconds are retained.

**Evidence job pending** is job creation to runner start. It can include
waiting for dependencies. **Runner queue** is the provider's separate queue
measurement. Missing or reversed timestamps are unknown, a genuine zero is
zero, and local runs without a CI job are not applicable. Old evidence lacking
these timestamps is not silently backfilled with pipeline creation time.

## Delivery loop

1. Develop and review locally, with accurate local substitutes for dependencies.
2. Run affected acceptance journeys once and retain their evidence fingerprints.
3. Build and deploy staging after bounded safety checks.
4. Run unexecuted full/deeper verification after staging; exercise real external
   test accounts there only when they require it.
5. Assemble complete evidence and validate the intended project data/user journey
   before production. A health endpoint alone does not establish usability.

Unknown impact expands the required scenario set; it does not require all of
that set to run before staging. Reuse requires matching code, contract, assets,
dependencies and capability/fixture context. Report-only corrections reuse the
original evidence. Exceptional robustness repeats record their reason.

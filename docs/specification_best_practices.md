# Specification best practices: integration blind spots

Acceptance scenarios should expose failures that component tests and static
screenshots routinely miss. A feature is not integrated merely because its
pure logic works or its final render looks correct.

## Value-flow prerequisite: one step is a smell

A one-step ATDD scenario usually proves only a page render or one integration
boundary. Acceptance steps must build on each other: real user activity →
persisted side effect → the user's visible benefit → downstream/admin evidence.
Adding numbered assertions around the same screenshot does not create a flow.

For activity that affects metrics, record a baseline, perform the real journey,
and prove exact deltas and the applicable personal and admin dashboard changes.
Check identity/cohort/time-window alignment, reload persistence, deduplication,
and pending/confirmed distinctions where relevant. Do not seed final aggregates
or manually emit a tracking request to stand in for JavaScript the UI must run.
Anonymous journeys prove local state and aggregates without inventing an account;
show later personal continuity if saving to an account is part of the flow.

Each scenario owns its activity and baseline. An admin scenario must create or
replay its own journey, not read leftovers from another scenario. Switch browser
identities when changing actors, retaining the causal link to the same activity.

Flag missing closure as `INCOMPLETE — acceptance coverage` in the canonical index
and delivery ledger even when ExUnit passes. Name the missing evidence and retain
the original contract pending approval. Coverage debt is not a product-defect
`ignored` status or an environment `skipped` status. Label intentional one-step
checks as smoke and link them to the full value-flow scenario.

## 1. Exercise interruptions while the user is interacting

For every surface that refreshes, reconnects, polls, streams, or remounts,
exercise the asynchronous boundary while interaction is in progress—not only
before and after it.

Preserve and assert the state that carries the user's intent:

- keyboard focus, cursor and selection;
- unsubmitted text, validation errors and pending submission state;
- scroll position and the item currently being inspected;
- open dialogs, disclosures, selected tabs and filters;
- keyboard navigation and assistive-technology announcements.

A periodic refresh that destroys and recreates controls is a state transition.
Specify its recovery behavior explicitly. Prefer stable controls with patched
content; where rebuilding is unavoidable, snapshot and restore interaction
state without overwriting newer user input.

## 2. Verify deployed composition, not only isolated logic

Tests often substitute temporary directories, fake services, permissive
credentials, or deterministic clocks. Record those substitutions and prove the
deployed process can see its real inputs:

- resolved filesystem paths and environment-variable precedence;
- service user, permissions and sandbox boundaries;
- endpoint, profile, account and host identity;
- startup ordering and source synchronization;
- durable state across worker, service and UI restarts.

An HTTP health response proves that a process is listening. It does not prove
that its sources have synchronized, that observations are current, or that the
UI is consuming the intended instance. Assert provenance, freshness and at
least one known real observation at the integration boundary.

## 3. Keep cross-surface evidence honest

Web previews can deterministically prove data and behavior, but they do not
prove native GNOME, macOS, iOS, terminal or notification rendering. Split the
claim when necessary:

1. executable evidence proves the state transition and correlation;
2. evidence from the real target surface proves native presentation and input;
3. the review bundle names what each artifact proves and does not imply that a
   fixture demonstrates live provenance.

Use the same stable scenario ID across the composite evidence, with a suffix
for a distinct surface step when useful.

## 4. Test the seams and temporal order

Include an integration matrix proportional to the risk:

| Seam | Frequently missed assertion |
| --- | --- |
| Poll or push refresh | Active input and focus survive the update |
| Reconnect or restart | Draft/view state and durable signals recover |
| Startup | Sources synchronize before the UI claims current state |
| Producer → aggregator | Identity, timestamp and provenance remain intact |
| Aggregator → native client | The intended instance and version consume the record |
| Focus/acknowledgement | Only a later transition clears the exact record |
| Failure path | Stale/unavailable state is explicit and does not invent success |

For event-driven behavior, capture timestamps on both sides of the boundary and
assert ordering. A successful final snapshot can conceal a signal that appeared
late, cleared early, or was read from the wrong source.

## 5. Review checklist

Before calling an interactive feature accepted, ask:

- What can refresh, reconnect, remount, restart or arrive concurrently?
- What is the operator doing at that exact moment?
- Which state must survive, and which state may deliberately reset?
- Does the deployed process read the same paths/endpoints as the test?
- Does readiness mean “process alive” or “sources synchronized”?
- Which artifact proves behavior, provenance and target-surface rendering?
- What observation would make a false green obvious?

Add a regression at the narrowest useful layer, but retain at least one
scenario across every seam whose failure would make the feature unusable.

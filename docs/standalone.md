# Standalone review tools

The harness owns `bin/xopen` and `bin/mdopen`; a private skills checkout and an
Elixir application are not required to use these tools. The preview engine is
Python standard library code. Markdown additionally requires Pandoc. Browser
opening uses macOS `open` or Linux `xdg-open`; Linux PDF preview optionally uses
Okular. Windows launchers are not yet verified.

```sh
bin/xopen --watch /absolute/path/review.html
bin/mdopen --watch /absolute/path/notes.md
```

For a second device on the tailnet, bind explicitly to this host's tailnet IP:

```sh
bin/xopen --watch --no-open --bind TAILNET_IP --port 8766 \
  --maxwait 86400 --root /absolute/path/docs /absolute/path/docs/review.html
```

Use the printed URL. The served root is an explicit exposure boundary; use the
smallest directory containing the document and its assets. Keep one canonical
HTML file per goal, update it in place, and retain its watcher. The preview's
close control stops the server. `--maxwait` sets its startup/idle lifetime.
Without a network collector, a static export cannot measure readership.

The engine and platform wrappers were moved from host-tools live-preview 1.0.6.
Compatibility launchers should delegate to an installed harness path after that
installation is verified. Preserve current host entry points until then.

## Capability boundaries

| Surface | Current evidence support | Remaining boundary |
| --- | --- | --- |
| Phoenix, Linux/macOS | Browser PNG/HTML, imported run/scenario/step review | Browser/runtime version must support the host OS |
| Email | Rendered message/preview evidence | Preview does not prove delivery |
| Telegram | Message timelines and rendered evidence | Live delivery uses a channel adapter |
| CLI/TUI | Structured output and terminal evidence | Interactive execution needs its platform adapter |
| GNOME | Presence native/runtime evidence | Linux-specific driver and collectors |
| iOS | Review in a browser | Native/device capture and physical Instruments collector are separate |
| Windows | Browser viewing | Native launchers and execution remain unverified |

Declare surface, OS/device, theme, execution mode and unavailable capabilities.
Do not infer native execution support from a portable HTML viewer.

## Review structured evidence with durable counts

The 0.11 candidate also includes a portable SQLite viewer:

```sh
bin/acceptance-review /absolute/path/evidence/evidence.json \
  --store /absolute/path/private-state/reviews.sqlite3 --environment dev
```

Open its printed URL and follow the run → scenario → step links. It uses the
same one-second browser observer and receipt format as the Phoenix mount.
Source edits refresh the open page; the close control stops the server.
The default bind is loopback; use `--bind TAILNET_IP` for another tailnet device.
Keep the SQLite file outside the served evidence directory. Only the evidence
root is exposed, and the server refuses traversal/hidden paths. Collection uses
an ephemeral page token; the network audience must be restricted to reviewers.

Exchange receipts explicitly through an authorized project artifact channel:

```sh
bin/acceptance-review evidence/evidence.json --store state/reviews.sqlite3 \
  --environment dev --export-receipts review-receipts.json
bin/acceptance-review evidence/evidence.json --store state/reviews.sqlite3 \
  --environment staging --import-receipts review-receipts.json
```

The same JSON imports through `mix acceptance.review_store import PROJECT FILE`.
Repeated imports do not increase counts. Separate stores are not automatically
synchronized. The viewer labels this boundary rather than implying global
freshness. This first portable surface supports images and textual evidence;
the full Phoenix rendered-page, schema, comparison and presentation controls
remain the reference integration. It does not yet have complete feature parity.

## Check retained acceptance results without compilation

```sh
bin/acceptance-gate tmp/atdd/status.env tmp/atdd/e2e.md
```

The Python standard-library command preserves the existing gate's status and
report checks. It never runs scenarios. For a complete release selection, also
pass `--evidence tmp/atdd/evidence.json --manifest tmp/acceptance-selection.json`;
the manifest's `all_ids` must all have accepted terminal outcomes. Known ignored
or skipped scenarios retain their explicit reasons and are not counted as passed.

CI can retain `priv/preview/acceptance_gate.py` with the evidence and invoke it
directly with Python. Consumers must preserve the evidence-producing job dependency
and the production gate, and remove dependency installation only from this
artifact-checking job. This is a rollout recipe; existing consumer pipelines have
not automatically switched to it.

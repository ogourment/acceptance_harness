import os
import hashlib
import json
import runpy
import shutil
import signal
import subprocess
import sys
import time
import threading
import urllib.error
import urllib.request
from pathlib import Path
from types import SimpleNamespace
import pytest


MODULE = runpy.run_path(
    str(Path(__file__).parents[2] / "priv" / "preview" / "linux" / "live-preview"),
    run_name="live_preview_test",
)
short_source_path = MODULE["short_source_path"]
Preview = MODULE["Preview"]
read_port_ledger = MODULE["read_port_ledger"]
write_port_ledger = MODULE["write_port_ledger"]
file_signature = MODULE["file_signature"]


def preview_fixture(tmp_path):
    source = tmp_path / "index.html"
    source.write_text("<html><body><main>First revision</main></body></html>")
    return Preview(SimpleNamespace(
        source=str(source), output=None, css=None, source_label=None,
        fallback_title="Preview", path_boundary_regex=r"tmp", mode="html",
        ready=str(tmp_path / "ready"), pidfile=str(tmp_path / "pid"),
        idle_timeout=12, startup_timeout=60,
    ))


def test_polling_recovers_changes_even_when_inotify_cannot_start(tmp_path, monkeypatch):
    preview = preview_fixture(tmp_path)
    assert preview.refresh()
    messages = MODULE["queue"].Queue()
    preview.add_client("test", messages)

    def unavailable(*args, **kwargs):
        raise OSError("Couldn't initialize inotify: Too many open files")

    monkeypatch.setattr(subprocess, "Popen", unavailable)
    watcher = threading.Thread(target=MODULE["watch"], args=(preview,))
    watcher.start()
    try:
        preview.source.write_text("<main>Second revision</main>")
        assert messages.get(timeout=3) == "data: reload\n\n"
        assert preview.synchronization()["error"] is None
    finally:
        preview.shutdown_requested.set()
        watcher.join(timeout=3)
    assert not watcher.is_alive()


def test_heartbeat_repairs_missed_changes_and_reports_missing_source(tmp_path):
    preview = preview_fixture(tmp_path)
    first = preview.synchronization()
    preview.source.write_text("<main>Second revision</main>")
    second = preview.synchronization()
    assert second["revision"] != first["revision"]
    assert second["revision"] == hashlib.sha256(preview.source.read_bytes()).hexdigest()
    assert second["error"] is None
    preview.source.unlink()
    assert preview.synchronization()["error"] is not None
    preview.source.write_text("<main>Restored</main>")
    assert preview.synchronization()["error"] is None


def test_failed_render_is_not_marked_current_and_retries(tmp_path, monkeypatch):
    preview = preview_fixture(tmp_path)
    preview.refresh()
    original = preview.rendered_signature
    preview.source.write_text("<main>Changed</main>")
    monkeypatch.setattr(preview, "render", lambda: False)
    assert preview.synchronization()["error"] == "Render failed — retrying"
    assert preview.rendered_signature == original
    monkeypatch.setattr(preview, "render", lambda: True)
    assert preview.synchronization()["error"] is None
    assert preview.rendered_signature != original


def test_real_server_heartbeat_checks_revision_without_watcher(tmp_path):
    preview = preview_fixture(tmp_path)
    import http.server
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), MODULE["make_handler"](preview))
    server.daemon_threads = True
    worker = threading.Thread(target=server.serve_forever)
    worker.start()
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{server.server_port}/") as response:
            assert response.headers["Cache-Control"] == "no-store"
        with urllib.request.urlopen(f"http://127.0.0.1:{server.server_port}/events?client=test", timeout=5) as response:
            assert response.readline() == b": connected\n"
            response.readline()
            preview.source.write_text("<main>Missed notification</main>")
            assert response.readline() == b"event: heartbeat\n"
            state = json.loads(response.readline().decode().removeprefix("data: "))
            assert state["revision"] == hashlib.sha256(preview.source.read_bytes()).hexdigest()
            assert state["error"] is None
    finally:
        preview.shutdown_requested.set()
        server.shutdown()
        server.server_close()
        worker.join(timeout=3)


def test_server_resolves_repository_links_from_configured_root(tmp_path):
    import http.server

    repository = tmp_path / "project"
    source = repository / "review" / "index.html"
    proposal = repository / "acceptance" / "proposals" / "HA-UPDATE-01.md"
    hidden = repository / ".git" / "config"
    source.parent.mkdir(parents=True)
    asset = source.parent / "assets" / "evidence.png"
    asset.parent.mkdir()
    proposal.parent.mkdir(parents=True)
    hidden.parent.mkdir(parents=True)
    source.write_text(
        '<img src="assets/evidence.png"><a href="../acceptance/proposals/HA-UPDATE-01.md">Proposal</a>'
    )
    asset.write_bytes(b"evidence-image")
    proposal.write_text("# Drain-safe updates\n", encoding="utf-8")
    hidden.write_text("secret-shaped metadata", encoding="utf-8")
    preview = Preview(SimpleNamespace(
        source=str(source), output=None, css=None, source_label=None,
        fallback_title="Preview", path_boundary_regex=r"tmp", mode="html",
        ready=str(tmp_path / "ready"), pidfile=str(tmp_path / "pid"),
        idle_timeout=12, startup_timeout=60, serve_root=str(repository),
    ))
    assert preview.refresh()
    server = http.server.ThreadingHTTPServer(
        ("127.0.0.1", 0), MODULE["make_handler"](preview)
    )
    server.daemon_threads = True
    worker = threading.Thread(target=server.serve_forever)
    worker.start()
    try:
        base = f"http://127.0.0.1:{server.server_port}"
        with urllib.request.urlopen(f"{base}/") as response:
            rendered = response.read().decode()
            assert '<base href="/review/">' in rendered
        with urllib.request.urlopen(f"{base}/review/assets/evidence.png") as response:
            assert response.read() == b"evidence-image"
        with urllib.request.urlopen(
            f"{base}/acceptance/proposals/HA-UPDATE-01.md"
        ) as response:
            rendered = response.read().decode()
            assert response.headers["Content-Type"] == "text/html; charset=utf-8"
            assert "<h1" in rendered
            assert "Drain-safe updates" in rendered
            assert "source=acceptance%2Fproposals%2FHA-UPDATE-01.md" in rendered
            assert "live-preview-status" in rendered
        with pytest.raises(urllib.error.HTTPError) as error:
            urllib.request.urlopen(f"{base}/.git/config")
        assert error.value.code == 404
    finally:
        preview.shutdown_requested.set()
        server.shutdown()
        server.server_close()
        worker.join(timeout=3)


def test_markdown_preview_serves_root_when_source_is_outside_output_dir(tmp_path):
    import http.server

    source = tmp_path / "project" / "handoff.md"
    output = tmp_path / "Documents" / "mdopen" / "handoff.html"
    source.parent.mkdir()
    output.parent.mkdir(parents=True)
    source.write_text("# Handoff\n", encoding="utf-8")
    output.write_text(
        '<html><head><link rel="stylesheet" href="mdopen.css"></head>'
        '<body><main>Handoff</main></body></html>', encoding="utf-8"
    )
    (output.parent / "mdopen.css").write_text("body { color: blue; }", encoding="utf-8")
    preview = Preview(SimpleNamespace(
        source=str(source), output=str(output), css=None, source_label=None,
        fallback_title="Handoff", path_boundary_regex=r"tmp", mode="markdown",
        ready=str(tmp_path / "ready"), pidfile=str(tmp_path / "pid"),
        idle_timeout=12, startup_timeout=60,
    ))
    server = http.server.ThreadingHTTPServer(
        ("127.0.0.1", 0), MODULE["make_handler"](preview)
    )
    server.daemon_threads = True
    worker = threading.Thread(target=server.serve_forever)
    worker.start()
    try:
        base = f"http://127.0.0.1:{server.server_port}"
        with urllib.request.urlopen(f"{base}/") as response:
            rendered = response.read().decode()
            assert response.status == 200
            assert '<base href="/">' in rendered
            assert "Handoff" in rendered
            assert "live-preview-status" in rendered
        with urllib.request.urlopen(f"{base}/mdopen.css") as response:
            assert response.read() == b"body { color: blue; }"
    finally:
        preview.shutdown_requested.set()
        server.shutdown()
        server.server_close()
        worker.join(timeout=3)


def test_linked_markdown_heartbeat_tracks_its_own_source(tmp_path):
    if not shutil.which("pandoc"):
        pytest.skip("pandoc is required")
    preview = preview_fixture(tmp_path)
    proposal = tmp_path / "proposal.md"
    proposal.write_text("# First proposal\n", encoding="utf-8")

    first = preview.synchronization(proposal)
    proposal.write_text("# Revised proposal\n", encoding="utf-8")
    second = preview.synchronization(proposal)

    assert first["error"] is None
    assert second["error"] is None
    assert first["revision"] != second["revision"]


def test_browser_repairs_stale_document_and_warns_when_source_unavailable(tmp_path):
    playwright = pytest.importorskip("playwright.sync_api")
    import http.server
    preview = preview_fixture(tmp_path)
    preview.source.write_text('<html><body style="min-height:3000px"><main>First revision</main></body></html>')
    edited_at = time.time() - 120
    os.utime(preview.source, (edited_at, edited_at))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), MODULE["make_handler"](preview))
    server.daemon_threads = True
    worker = threading.Thread(target=server.serve_forever)
    worker.start()
    try:
        with playwright.sync_playwright() as engine:
            browser = engine.chromium.launch()
            page = browser.new_page()
            url = f"http://127.0.0.1:{server.server_port}/#review"
            # Deliberately NO watcher: only independently verified SSE revisions
            # can repair this stale loaded page, including missed reload messages.
            page.goto(url)
            playwright.expect(page.locator("#live-preview-sync")).to_have_class("live-preview-healthy")
            playwright.expect(page.locator("#live-preview-sync")).to_have_attribute(
                "aria-label", "Live preview up to date"
            )
            freshness = page.locator("#live-preview-freshness")
            playwright.expect(freshness).to_be_visible()
            playwright.expect(freshness).to_have_text("Edited 2 minutes ago")
            page.clock.set_fixed_time(edited_at + 180)
            playwright.expect(freshness).to_have_text("Edited 3 minutes ago")
            page.clock.set_fixed_time(time.time())
            page.evaluate("scrollTo(0, 500)")
            preview.source.write_text('<html><body style="min-height:3000px"><main>New revision</main></body></html>')
            playwright.expect(page.locator("main")).to_have_text("New revision", timeout=7000)
            assert page.url.endswith("#review")
            playwright.expect(page.locator("#live-preview-sync")).to_have_class("live-preview-healthy")
            assert page.evaluate("scrollY") == 500
            preview.source.unlink()
            playwright.expect(page.locator("#live-preview-sync")).to_have_text("Preview unavailable", timeout=5000)
            playwright.expect(page.locator("html")).to_have_class("live-preview-disconnected")
            preview.source.write_text("<html><body><main>Recovered revision</main></body></html>")
            playwright.expect(page.locator("main")).to_have_text("Recovered revision", timeout=7000)
            playwright.expect(page.locator("#live-preview-sync")).to_have_class("live-preview-healthy")
            stale_html = preview.html()
            preview.source.write_bytes(b"<html>\r\n<body><main>Initial handshake revision</main></body></html>")
            page.route("**/", lambda route: route.fulfill(body=stale_html, content_type="text/html"), times=1)
            page.goto(url)
            playwright.expect(page.locator("main")).to_have_text("Initial handshake revision", timeout=7000)
            playwright.expect(page.locator("#live-preview-sync")).to_have_class("live-preview-healthy")
            browser.close()
    finally:
        preview.shutdown_requested.set()
        server.shutdown()
        server.server_close()
        worker.join(timeout=3)


def test_preview_status_yields_to_visible_page_modal(tmp_path):
    playwright = pytest.importorskip("playwright.sync_api")
    import http.server

    preview = preview_fixture(tmp_path)
    preview.source.write_text("""
        <html><body>
          <button id="open" onclick="document.querySelector('#lightbox').classList.add('open')">Open evidence</button>
          <div id="lightbox" role="dialog" aria-modal="true" style="display:none"></div>
          <style>#lightbox.open { display: block !important; position: fixed; inset: 0; }</style>
        </body></html>
    """)
    server = http.server.ThreadingHTTPServer(
        ("127.0.0.1", 0), MODULE["make_handler"](preview)
    )
    server.daemon_threads = True
    worker = threading.Thread(target=server.serve_forever)
    worker.start()
    try:
        with playwright.sync_playwright() as engine:
            browser = engine.chromium.launch()
            page = browser.new_page()
            page.goto(f"http://127.0.0.1:{server.server_port}/")
            status = page.locator("#live-preview-status")
            playwright.expect(status).to_be_visible()
            page.locator("#open").click()
            playwright.expect(status).to_be_hidden()
            page.locator("#lightbox").evaluate("el => el.classList.remove('open')")
            playwright.expect(status).to_be_visible()
            browser.close()
    finally:
        preview.shutdown_requested.set()
        server.shutdown()
        server.server_close()
        worker.join(timeout=3)


def test_preview_document_watches_visible_modals_without_page_cooperation(tmp_path):
    preview = preview_fixture(tmp_path)
    rendered = preview.html()

    assert ".live-preview-modal-open #live-preview-status" in rendered
    assert 'dialog[open], [role="dialog"][aria-modal="true"]' in rendered
    assert "new MutationObserver(syncPreviewChrome)" in rendered


def test_browser_recreates_event_stream_after_proxy_returns_non_200(tmp_path):
    playwright = pytest.importorskip("playwright.sync_api")
    import http.server
    preview = preview_fixture(tmp_path)
    handler = MODULE["make_handler"](preview)
    attempts = []

    class RecoveringProxy(handler):
        def do_GET(self):
            if self.path.startswith("/events"):
                attempts.append(time.monotonic())
                if len(attempts) <= 2:
                    self.send_error(502, "Upstream temporarily restarting")
                    return
            super().do_GET()

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), RecoveringProxy)
    server.daemon_threads = True
    worker = threading.Thread(target=server.serve_forever)
    worker.start()
    try:
        with playwright.sync_playwright() as engine:
            browser = engine.chromium.launch()
            page = browser.new_page()
            page.goto(f"http://127.0.0.1:{server.server_port}/#review")
            playwright.expect(page.locator("#live-preview-sync")).to_have_text("Disconnected — retrying")
            playwright.expect(page.locator("html")).to_have_class("live-preview-disconnected")
            assert page.evaluate("events.readyState") == 2
            playwright.expect(page.locator("#live-preview-sync")).to_have_class(
                "live-preview-healthy", timeout=12000
            )
            assert len(attempts) == 3
            assert attempts[1] - attempts[0] >= 1
            preview.source.write_text("<html><body><main>Recovered after proxy outage</main></body></html>")
            playwright.expect(page.locator("main")).to_have_text("Recovered after proxy outage", timeout=7000)
            assert page.url.endswith("#review")
            browser.close()
    finally:
        preview.shutdown_requested.set()
        server.shutdown()
        server.server_close()
        worker.join(timeout=3)


def test_tmp_tree_preserves_repository_context():
    source = "/home/olivierg/work/elixir/repo-ui-toolbox/tmp/atdd-review/index.html"

    assert short_source_path(source) == "repo-ui-toolbox/.../index.html"


def test_tmp_tree_preserves_meaningful_descendants():
    source = (
        "/home/olivierg/work/elixir/ecojeux/tmp/atdd-review/"
        "alliances-francaises-training/index.html"
    )

    assert short_source_path(source) == (
        "ecojeux/.../alliances-francaises-training/index.html"
    )


def test_ordinary_path_keeps_parent_and_filename():
    assert short_source_path("/srv/project/review/index.html") == "review/index.html"


def test_boundary_regex_is_configurable():
    source = "/srv/project/generated/reports/summary.html"

    assert short_source_path(source, r"tmp|generated") == "project/.../summary.html"


def test_rendered_pill_uses_collapsed_path(tmp_path):
    source = tmp_path / "repo-ui-toolbox" / "tmp" / "atdd-review" / "index.html"
    source.parent.mkdir(parents=True)
    source.write_text("<html><body>Review</body></html>", encoding="utf-8")
    args = SimpleNamespace(
        source=str(source), output=None, css=None, source_label=None,
        fallback_title="Preview", path_boundary_regex=r"tmp", mode="html",
        ready=str(tmp_path / "ready"), pidfile=str(tmp_path / "pid"),
        idle_timeout=12, startup_timeout=60, port_ledger=None,
    )

    rendered = Preview(args).html()

    assert 'data-short-path="repo-ui-toolbox/.../index.html"' in rendered
    assert ">repo-ui-toolbox/.../index.html</code>" in rendered


def test_rendered_preview_greys_content_and_reports_event_disconnect(tmp_path):
    source = tmp_path / "review" / "index.html"
    source.parent.mkdir(parents=True)
    source.write_text("<html><body><main>Review</main></body></html>", encoding="utf-8")
    args = SimpleNamespace(
        source=str(source), output=None, css=None, source_label=None,
        fallback_title="Preview", path_boundary_regex=r"tmp", mode="html",
        ready=str(tmp_path / "ready"), pidfile=str(tmp_path / "pid"),
        idle_timeout=12, startup_timeout=60, port_ledger=None,
    )

    rendered = Preview(args).html()

    assert "live-preview-disconnected" in rendered
    assert "filter: grayscale(1)" in rendered
    assert "Disconnected — retrying" in rendered
    assert "events.onerror" in rendered
    assert "events.onopen" in rendered
    assert "events.addEventListener('heartbeat'" in rendered
    assert "Date.now() - lastHeartbeatAt > 6500" in rendered


def test_rendered_preview_can_copy_path_from_insecure_lan_origin(tmp_path):
    source = tmp_path / "review" / "index.html"
    source.parent.mkdir(parents=True)
    source.write_text("<html><body><main>Review</main></body></html>", encoding="utf-8")
    args = SimpleNamespace(
        source=str(source), output=None, css=None, source_label=None,
        fallback_title="Preview", path_boundary_regex=r"tmp", mode="html",
        ready=str(tmp_path / "ready"), pidfile=str(tmp_path / "pid"),
        idle_timeout=12, startup_timeout=60, port_ledger=None,
    )

    rendered = Preview(args).html()

    assert "window.isSecureContext && navigator.clipboard?.writeText" in rendered
    assert "document.execCommand('copy')" in rendered
    assert "field.setSelectionRange(0, field.value.length)" in rendered
    assert "crypto.randomUUID?.()" in rendered
    assert "Math.random().toString(16)" in rendered


def test_freshness_uses_source_mtime_not_render_time(tmp_path):
    source = tmp_path / "review.md"
    output = tmp_path / "review.html"
    source.write_text("# Review\n", encoding="utf-8")
    output.write_text("<html><body>Review</body></html>", encoding="utf-8")
    source_modified_at = 1_700_000_000
    output_modified_at = 1_800_000_000
    os.utime(source, (source_modified_at, source_modified_at))
    os.utime(output, (output_modified_at, output_modified_at))
    args = SimpleNamespace(
        source=str(source), output=str(output), css=None, source_label=None,
        fallback_title="Review", path_boundary_regex=r"tmp", mode="markdown",
        ready=str(tmp_path / "ready"), pidfile=str(tmp_path / "pid"),
        idle_timeout=12, startup_timeout=60, port_ledger=None,
    )

    rendered = Preview(args).html()

    assert "new Date(1700000000000)" in rendered
    assert "new Date(1800000000000)" not in rendered


def test_port_ledger_round_trips_a_valid_port(tmp_path):
    ledger = tmp_path / "preview.port"

    write_port_ledger(ledger, 41845)

    assert read_port_ledger(ledger) == 41845
    assert oct(ledger.stat().st_mode & 0o777) == "0o600"


def test_port_ledger_rejects_invalid_content(tmp_path):
    ledger = tmp_path / "preview.port"
    ledger.write_text("not-a-port\n", encoding="ascii")

    assert read_port_ledger(ledger) is None


def test_file_signature_notices_an_atomic_save(tmp_path):
    source = tmp_path / "review.html"
    replacement = tmp_path / "replacement.html"
    source.write_text("first", encoding="utf-8")
    before = file_signature(source)

    replacement.write_text("second version", encoding="utf-8")
    replacement.replace(source)

    assert file_signature(source) != before


def test_mdopen_platforms_style_attention_pills():
    host_tools = (Path(__file__).parents[2] / "priv" / "preview")
    for platform in ("linux", "macos"):
        script = (host_tools / platform / "mdopen").read_text(encoding="utf-8")
        assert ".attention-pill" in script
        assert "prefers-color-scheme: dark" in script


def test_macos_mdopen_renders_gfm_without_opening_browser(tmp_path):
    if sys.platform != "darwin" or not shutil.which("pandoc"):
        return

    source = tmp_path / "proposal.md"
    render_dir = tmp_path / "rendered"
    source.write_text("# Proposed behavior\n\n- [ ] Review this\n", encoding="utf-8")
    script = (Path(__file__).parents[2] / "priv" / "preview") / "macos" / "mdopen"

    subprocess.run(
        ["sh", str(script), "--html", str(source)],
        check=True,
        env={
            "HOME": str(tmp_path),
            "MDOPEN_DIR": str(render_dir),
            "MDOPEN_NO_OPEN": "true",
            "PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        },
    )

    rendered = (render_dir / "proposal.html").read_text(encoding="utf-8")
    assert "<title>Proposed behavior</title>" in rendered
    assert 'type="checkbox"' in rendered
    assert "Read-only Markdown preview" in rendered


def test_macos_mdopen_watch_rerenders_after_save(tmp_path):
    if sys.platform != "darwin" or not shutil.which("pandoc"):
        return

    source = tmp_path / "watched.md"
    render_dir = tmp_path / "rendered"
    runtime_dir = tmp_path / "runtime"
    runtime_dir.mkdir()
    source.write_text("# Watched\n\nFirst version\n", encoding="utf-8")
    script = (Path(__file__).parents[2] / "priv" / "preview") / "macos" / "mdopen"
    env = {
        "HOME": str(tmp_path),
        "MDOPEN_DIR": str(render_dir),
        "MDOPEN_NO_OPEN": "true",
        "TMPDIR": str(runtime_dir),
        "PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
    }

    try:
        result = subprocess.run(
            ["sh", str(script), "--watch", str(source)],
            check=True,
            capture_output=True,
            text=True,
            env=env,
        )
        assert result.stdout.startswith("http://127.0.0.1:")

        output = render_dir / "watched.html"
        assert "First version" in output.read_text(encoding="utf-8")
        source.write_text("# Watched\n\nSecond version\n", encoding="utf-8")
        for _ in range(40):
            if "Second version" in output.read_text(encoding="utf-8"):
                break
            time.sleep(0.1)
        else:
            raise AssertionError("watched Markdown was not rerendered")
    finally:
        for pidfile in runtime_dir.glob("mdopen-watch/*.pid"):
            try:
                pid = int(pidfile.read_text(encoding="ascii").strip())
                os.kill(pid, signal.SIGTERM)
            except (OSError, ValueError):
                pass


def test_xopen_platforms_support_remote_handoff_without_opening_locally():
    host_tools = (Path(__file__).parents[2] / "priv" / "preview")
    for platform in ("linux", "macos"):
        script = (host_tools / platform / "xopen").read_text(encoding="utf-8")
        assert "--no-open" in script
        assert "--maxwait" in script
        assert "startup_timeout=600" in script
        assert '--startup-timeout "$startup_timeout"' in script
        assert '--idle-timeout "$idle_timeout"' in script
        assert "--root" in script
        assert "rev-parse --show-toplevel" in script
        assert '--serve-root "$serve_root"' in script
        assert 'ledger="$ledger_dir/$port_key.port"' in script

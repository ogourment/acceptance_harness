"""Linked documents use the shared xopen/mdopen preview session."""
import hashlib
import http.server
import json
import threading
import urllib.request

import pytest
from test_live_preview import MODULE, preview_fixture


@pytest.mark.parametrize("entry_mode", ["html", "markdown"])
@pytest.mark.parametrize("extension", ["html", "htm"])
def test_linked_html_is_decorated_and_tracks_its_own_revision(tmp_path, extension, entry_mode):
    preview = preview_fixture(tmp_path)
    if entry_mode == "markdown":
        preview.source = tmp_path / "review.md"
        preview.source.write_text("# Review\n")
        preview.mode = "markdown"
    linked = tmp_path / f"backlog.{extension}"
    linked.write_text('<html><body><main>Iteration one</main></body></html>')
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), MODULE["make_handler"](preview))
    server.daemon_threads = True
    worker = threading.Thread(target=server.serve_forever)
    worker.start()
    try:
        base = f"http://127.0.0.1:{server.server_port}"
        with urllib.request.urlopen(f"{base}/{linked.name}") as response:
            document = response.read().decode()
            assert 'id="live-preview-status"' in document
            assert f'data-path="{linked}"' in document
            assert f"source={linked.name}" in document
        with urllib.request.urlopen(f"{base}/events?client=linked&source={linked.name}", timeout=5) as response:
            assert response.readline() == b": connected\n"
            response.readline()
            linked.write_text('<html><body><main>Iteration two</main></body></html>')
            assert response.readline() == b"event: heartbeat\n"
            state = json.loads(response.readline().decode().removeprefix("data: "))
            assert state["revision"] == hashlib.sha256(linked.read_bytes()).hexdigest()
            assert state["error"] is None
        with urllib.request.urlopen(f"{base}/{linked.name}") as response:
            assert '<main>Iteration two</main>' in response.read().decode()
    finally:
        preview.shutdown_requested.set()
        server.shutdown()
        server.server_close()
        worker.join(timeout=3)

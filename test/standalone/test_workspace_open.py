"""Workspace-directed previews never select or move an existing browser window."""

import importlib.util
import subprocess
from pathlib import Path

import pytest


SCRIPT = Path(__file__).parents[2] / "priv/preview/linux/open-workspace.py"
spec = importlib.util.spec_from_file_location("open_workspace", SCRIPT)
opener = importlib.util.module_from_spec(spec)
spec.loader.exec_module(opener)


def test_new_firefox_window_is_placed_on_one_based_workspace(monkeypatch, capsys):
    monkeypatch.setenv("XDG_SESSION_TYPE", "x11")
    calls = []
    snapshots = iter([
        "0x111 2 Navigator.firefox_firefox host Existing window\n",
        "0x111 2 Navigator.firefox_firefox host Existing window\n"
        "0x222 0 Navigator.firefox_firefox host New window\n",
        "0x111 2 Navigator.firefox_firefox host Existing window\n"
        "0x222 4 Navigator.firefox_firefox host New window\n",
    ])

    def fake_run(*args):
        calls.append(args)
        if args == ("wmctrl", "-d"):
            return "0 - First\n4 - Fifth\n"
        if args == ("xdg-settings", "get", "default-web-browser"):
            return "firefox_firefox.desktop\n"
        if args == ("wmctrl", "-lx"):
            return next(snapshots)
        return ""

    launches = []
    monkeypatch.setattr(opener, "run", fake_run)
    monkeypatch.setattr(subprocess, "Popen", lambda args, **kwargs: launches.append(args))
    opener.open_on_workspace("5", "https://example.org/review")

    assert launches == [["firefox", "--new-window", "https://example.org/review"]]
    assert ("wmctrl", "-ir", "0x222", "-t", "4") in calls
    assert ("wmctrl", "-ir", "0x111", "-t", "4") not in calls
    assert "workspace 5" in capsys.readouterr().out


@pytest.mark.parametrize("number", ["0", "nine", "-1"])
def test_invalid_workspace_rejected_before_browser_launch(monkeypatch, number):
    monkeypatch.setattr(subprocess, "Popen", lambda *_args, **_kwargs: pytest.fail("launched"))
    with pytest.raises(ValueError, match="one-based"):
        opener.open_on_workspace(number, "https://example.org")


def test_missing_workspace_rejected_before_browser_launch(monkeypatch):
    monkeypatch.setenv("XDG_SESSION_TYPE", "x11")
    monkeypatch.setattr(opener, "run", lambda *_args: "0 - First\n")
    monkeypatch.setattr(subprocess, "Popen", lambda *_args, **_kwargs: pytest.fail("launched"))
    with pytest.raises(ValueError, match="does not exist"):
        opener.open_on_workspace("5", "https://example.org")

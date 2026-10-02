#!/usr/bin/env python3
"""Open a URL in a new Firefox window on a verified X11 workspace."""

import os
import re
import subprocess
import sys
import time
from pathlib import Path


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def firefox_windows():
    windows = {}
    for line in run("wmctrl", "-lx").splitlines():
        fields = line.split(None, 4)
        if len(fields) >= 3 and "firefox" in fields[2].lower():
            windows[fields[0].lower()] = int(fields[1])
    return windows


def workspace_exists(index):
    return any(
        re.match(r"^\s*" + str(index) + r"\s", line)
        for line in run("wmctrl", "-d").splitlines()
    )


def open_on_workspace(number, target):
    if not number.isdecimal() or int(number) < 1:
        raise ValueError("--workspace must be a one-based positive desktop number")
    index = int(number) - 1
    if os.environ.get("XDG_SESSION_TYPE", "").lower() != "x11":
        raise ValueError("--workspace requires an X11 desktop session")
    if not workspace_exists(index):
        raise ValueError(f"workspace {number} does not exist")
    browser = run("xdg-settings", "get", "default-web-browser").strip().lower()
    if "firefox" not in browser:
        raise ValueError(f"--workspace currently requires Firefox as default browser (found {browser})")
    if not (target.startswith("http://") or target.startswith("https://") or target.startswith("file://")):
        path = Path(target).resolve()
        if path.suffix.lower() not in (".html", ".htm") or not path.is_file():
            raise ValueError("--workspace accepts HTTP(S) URLs or local HTML files")
        target = path.as_uri()

    before = set(firefox_windows())
    subprocess.Popen(["firefox", "--new-window", target], stdin=subprocess.DEVNULL,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        windows = firefox_windows()
        new = set(windows) - before
        if len(new) > 1:
            raise RuntimeError("multiple new Firefox windows appeared; none was moved")
        if len(new) == 1:
            window = new.pop()
            run("wmctrl", "-ir", window, "-t", str(index))
            if firefox_windows().get(window) != index:
                raise RuntimeError(f"Firefox window {window} was not placed on workspace {number}")
            print(f"Opened Firefox window {window} on workspace {number}: {target}")
            return
        time.sleep(0.1)
    raise RuntimeError("Firefox did not create a new window; workspace placement is unverified")


if __name__ == "__main__":
    try:
        open_on_workspace(*sys.argv[1:])
    except (OSError, subprocess.CalledProcessError, ValueError, RuntimeError) as error:
        print(f"xopen: {error}", file=sys.stderr)
        sys.exit(1)

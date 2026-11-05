#!/usr/bin/env python3
"""Check real Dock image loading and empty/full changes with an isolated Trash."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

project = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(project))
from scripts.install_niri import quickshell

with tempfile.TemporaryDirectory(prefix="macshell-trash-test-") as directory:
    root = Path(directory)
    for name in ("home", "cache", "config", "data", "settings", "runtime"):
        (root / name).mkdir()
    (root / "runtime").chmod(0o700)
    display = os.environ.get("WAYLAND_DISPLAY", "")
    if display and not display.startswith("/"):
        display = str(Path(os.environ["XDG_RUNTIME_DIR"]) / display)
    shutil.copytree(project / "MacShell", root / "shell")
    source = root / "shell/MacDock.qml"
    text = source.read_text()
    needle = '                                MultiEffect {\n                                    visible: !cell.isSep && !cell.thumbReady'
    if text.count(needle) != 1:
        raise RuntimeError("Dock image probe insertion point changed")
    source.write_text(text.replace(needle, (project / "tests/dock-trash-native.qml").read_text() + "\n" + needle))
    env = dict(os.environ, HOME=str(root / "home"), XDG_CACHE_HOME=str(root / "cache"),
               XDG_CONFIG_HOME=str(root / "config"), XDG_DATA_HOME=str(root / "data"),
               XDG_RUNTIME_DIR=str(root / "runtime"), WAYLAND_DISPLAY=display,
               MACSHELL_SETTINGS_HOME=str(root / "settings"), NIRI_SOCKET=str(root / "no-session"),
               QT_QPA_PLATFORM="wayland", QT_QPA_PLATFORMTHEME="", QT_QUICK_CONTROLS_STYLE="Basic",
               DBUS_SESSION_BUS_ADDRESS="unix:path=" + str(root / "no-bus"),
               DBUS_SYSTEM_BUS_ADDRESS="unix:path=" + str(root / "no-bus"))
    logpath = root / "log"
    with logpath.open("w") as log:
        process = subprocess.Popen([quickshell(), "-p", str(root / "shell")], env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 22
            while process.poll() is None and time.monotonic() < deadline:
                time.sleep(.1)
            if process.poll() is None:
                raise RuntimeError("Dock Trash test timed out")
        finally:
            if process.poll() is None:
                process.terminate(); process.wait(timeout=5)
    output = logpath.read_text()
    if process.returncode or "DOCK_TRASH_PASS" not in output:
        raise RuntimeError(output[-10000:])
    print(next(line for line in output.splitlines() if "DOCK_TRASH_PASS" in line))

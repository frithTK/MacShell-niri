#!/usr/bin/env python3
"""Exercise asynchronous window-preview refreshes in an isolated Qt instance."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from PIL import Image

project = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(project))
from scripts.install_niri import quickshell

with tempfile.TemporaryDirectory(prefix="macshell-preview-reload-") as directory:
    root = Path(directory)
    shell = root / "shell"
    shutil.copytree(project / "MacShell", shell)
    shutil.copy2(project / "tests/niri-preview-reload.qml", shell / "shell.qml")
    for name, color in (("first", "#2167b5"), ("second", "#b56721")):
        Image.new("RGB", (2048, 2048), color).save(root / (name + ".png"))
    (root / "runtime").mkdir(mode=0o700)
    environment = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_QPA_PLATFORMTHEME="",
                       XDG_RUNTIME_DIR=str(root / "runtime"), XDG_CONFIG_HOME=str(root / "config"),
                       XDG_CACHE_HOME=str(root / "cache"), NIRI_SOCKET=str(root / "no-session"),
                       DBUS_SESSION_BUS_ADDRESS="unix:path=" + str(root / "no-bus"),
                       MACSHELL_PREVIEW_FIRST=(root / "first.png").as_uri(),
                       MACSHELL_PREVIEW_SECOND=(root / "second.png").as_uri())
    result = subprocess.run([quickshell(), "-p", str(shell)], env=environment, text=True,
                            capture_output=True, timeout=15)
    log = result.stdout + result.stderr
    for line in log.splitlines():
        if "MACSHELL_PREVIEW_RELOAD_" in line or "TypeError" in line or "ReferenceError" in line:
            print(line)
    if result.returncode or "MACSHELL_PREVIEW_RELOAD_PASS" not in log:
        print(log, file=sys.stderr)
        raise SystemExit(result.returncode or 1)

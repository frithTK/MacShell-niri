#!/usr/bin/env python3
"""Check widget storage in a short-lived native layer with isolated settings."""
import os
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

project = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(project))
from scripts.install_niri import quickshell

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    for name in ("cache", "config", "settings"):
        (root / name).mkdir()
    (root / "settings/macwidgets").mkdir()
    legacy = {"tempUnit": "C", "locMode": "auto", "cityName": "", "widgets": [
        {"id": "old-clock", "type": "clock", "style": "dark", "size": "small", "x": 21, "y": 56},
        {"id": "future", "type": "agenda", "style": "custom", "size": "wide", "x": -20, "y": 10, "custom": {"keep": True}}]}
    (root / "settings/macwidgets/settings.json").write_text(json.dumps(legacy))
    shutil.copytree(project / "MacShell", root / "shell")
    shutil.copyfile(project / "tests/widget-catalog.qml", root / "shell/shell.qml")
    environment = dict(
        os.environ,
        QT_QPA_PLATFORM="wayland",
        QT_QPA_PLATFORMTHEME="",
        QT_QUICK_CONTROLS_STYLE="Basic",
        XDG_CACHE_HOME=str(root / "cache"),
        XDG_CONFIG_HOME=str(root / "config"),
        MACSHELL_SETTINGS_HOME=str(root / "settings"),
        NIRI_SOCKET=str(root / "no-session"),
        DBUS_SESSION_BUS_ADDRESS="unix:path=" + str(root / "no-bus"),
        DBUS_SYSTEM_BUS_ADDRESS="unix:path=" + str(root / "no-bus"),
    )
    try:
        result = subprocess.run([quickshell(), "-p", str(root / "shell")], env=environment,
                                capture_output=True, text=True, timeout=10)
        log = result.stdout + result.stderr
        code = result.returncode
    except subprocess.TimeoutExpired as error:
        log = (error.stdout or b"").decode(errors="replace") + (error.stderr or b"").decode(errors="replace")
        code = 1
        print("Native widget check timed out.")
    Path("/tmp/macshell-widget-catalog-native.log").write_text(log)
    for line in log.splitlines():
        if any(word in line for word in ("ERROR", "Error", "FAIL", "PASS", "Binding loop")):
            print(line)
    if code or "MACSHELL_WIDGET_CATALOG_PASS" not in log:
        raise SystemExit(code or 1)

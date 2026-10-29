#!/usr/bin/env python3
"""Check production MacLock text offscreen, with preview enabled and no authentication."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

project = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(project))
sys.path.insert(0, str(project / "MacShell"))
from scripts.install_niri import quickshell
from locale_preferences import Preferences


def main():
    with tempfile.TemporaryDirectory(prefix="macshell-maclock-language-") as directory:
        root = Path(directory)
        lock = root / "lock"
        shutil.copytree(project / "MacLock", lock)
        path = lock / "shell.qml"
        source = path.read_text().replace("import QtQuick\n", "import QtQuick\nimport QtQuick.Window\n", 1)
        # Use a normal offscreen window for the preview; the production lock stays disabled.
        source = source.replace("        PanelWindow {\n            id: pw", "        Window {\n            width: 1000; height: 800; visible: true\n            id: pw")
        source = source.replace("            screen: modelData\n", "")
        for line in ("            anchors { top: true; bottom: true; left: true; right: true }\n",
                     "            exclusionMode: ExclusionMode.Ignore\n",
                     "            WlrLayershell.layer: WlrLayer.Overlay\n",
                     '            WlrLayershell.namespace: "maclock-preview"\n',
                     '            WlrLayershell.keyboardFocus: Quickshell.env("MACLOCK_PREVIEW_KB") === "1" && modelData.name === root.primary ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None\n'):
            source = source.replace(line, "")
        source = source.replace("ShellRoot {", "ShellRoot {\n    Timer { interval: 100; repeat: true; running: true; onTriggered: if (!root.preview || lock.locked || pam.active) { console.error(\"MACLOCK_LANGUAGE_FAIL: real lock/auth activated\"); Qt.exit(1); } }\n", 1)
        path.write_text(source)
        path = lock / "LockScreen.qml"
        source = path.read_text().replace("    id: ls\n", "    id: ls\n" + (project / "tests/maclock-language.qml").read_text(), 1)
        path.write_text(source)
        for name in ("runtime", "cache", "config", "home", "settings"):
            (root / name).mkdir(mode=0o700)
        preferences = Preferences(root / "config/environment.d/90-macshell-locale.conf", ["C"], {})
        state = preferences.save(dict(ui="ru", session="C", region="system"), "missing")
        env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_QUICK_BACKEND="software", QT_QPA_PLATFORMTHEME="", QT_QUICK_CONTROLS_STYLE="Basic",
            XDG_CACHE_HOME=str(root / "cache"), XDG_CONFIG_HOME=str(root / "config"), XDG_RUNTIME_DIR=str(root / "runtime"),
            MACSHELL_SETTINGS_HOME=str(root / "settings"), HOME=str(root / "home"), USER="Demo", MACLOCK_PREVIEW="1",
            NIRI_SOCKET=str(root / "no-session"), DBUS_SESSION_BUS_ADDRESS="unix:path=" + str(root / "no-bus"),
            DBUS_SYSTEM_BUS_ADDRESS="unix:path=" + str(root / "no-bus"), PIPEWIRE_REMOTE="macshell-no-audio")
        env.pop("DISPLAY", None); env.pop("WAYLAND_DISPLAY", None)
        log_path = Path("/tmp/macshell-maclock-language.log")
        with log_path.open("w") as output:
            process = subprocess.Popen([quickshell(), "-p", str(lock)], env=env, stdout=output, stderr=subprocess.STDOUT)
            try:
                deadline, stage = time.monotonic() + 25, 0
                while process.poll() is None and time.monotonic() < deadline:
                    log = log_path.read_text()
                    if stage == 0 and "MACLOCK_LANGUAGE_RU_READY" in log:
                        state = preferences.save(dict(ui="en", session="C", region="system"), state["token"]); stage = 1
                    elif stage == 1 and "MACLOCK_LANGUAGE_EN_READY" in log:
                        state = preferences.save(dict(ui="ru", session="C", region="system"), state["token"]); stage = 2
                    time.sleep(.05)
                if process.poll() is None:
                    raise RuntimeError("MacLock language check timed out")
            finally:
                if process.poll() is None:
                    process.terminate(); process.wait(timeout=5)
        log = log_path.read_text()
        for line in log.splitlines():
            if re.search(r"MACLOCK_LANGUAGE|TypeError|ReferenceError|Binding loop|Unable to assign", line):
                print(line)
        if process.returncode or "MACSHELL_MACLOCK_LANGUAGE_PASS" not in log or re.search(r"TypeError|ReferenceError|Binding loop|Unable to assign", log):
            raise SystemExit(process.returncode or 1)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Save the system language through real Settings, then test a new localized process."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

project = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(project))
from scripts.install_niri import quickshell


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--capture", type=Path)
    args = parser.parse_args()
    if args.capture:
        args.capture.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="macshell-system-language-") as directory:
        root = Path(directory)
        shell = root / "shell"
        shutil.copytree(project / "MacShell", shell)
        path = shell / "shell.qml"
        source = path.read_text().replace("import QtQuick\n", "import QtQuick\nimport QtQuick.Window\nimport QtTest\n", 1)
        path.write_text(source.replace("ShellRoot {", "ShellRoot {\n" + (project / "tests/system-language-native.qml").read_text(), 1))
        path = shell / "MacDock.qml"
        source = path.read_text().replace("    id: root\n", "    id: root\n    function testWindow() { return prefsWindow; }\n", 1)
        path.write_text(source)
        path = shell / "ClockApp.qml"
        source = path.read_text().replace("    id: root\n", "    id: root\n    property bool testAllowRing: false\n    property var testRingRecord: null\n    function testWindow() { return win; }\n    function testBanner() { return banner; }\n", 1)
        # This probe verifies action identity, never playback or a physical alarm.
        source = source.replace("function ring(r) {", "function ring(r) { if (!root.testAllowRing) { console.error(\"SYSTEM_LANGUAGE_AUDIO_FORBIDDEN\"); Qt.exit(1); return; } root.testRingRecord = r; root.ringing = r; return;", 1)
        path.write_text(source)
        for name in ("cache", "config", "home", "settings/macbar", "settings/macdock"):
            (root / name).mkdir(parents=True)
        (root / "settings/macbar/settings.json").write_text(json.dumps(dict(
            barEnabled=False, spotlightEnabled=False, ccEnabled=False, notificationsEnabled=False,
            clipHistory=False, uiSounds=False, autoContrast=False, barGlass=False, statsMetrics=[])))
        (root / "settings/macdock/settings.json").write_text(json.dumps(dict(dockEnabled=False, windowCapture=False)))
        env = dict(os.environ, QT_QPA_PLATFORM="wayland", QT_QPA_PLATFORMTHEME="", QT_QUICK_CONTROLS_STYLE="Basic", MACSHELL_CLOCK_SERVICE="0",
            XDG_CACHE_HOME=str(root / "cache"), XDG_CONFIG_HOME=str(root / "config"), MACSHELL_SETTINGS_HOME=str(root / "settings"),
            HOME=str(root / "home"), USER="Demo", LANG="en_US.utf8", LC_MESSAGES="en_US.utf8", LANGUAGE="en",
            NIRI_SOCKET=str(root / "no-session"), DBUS_SESSION_BUS_ADDRESS="unix:path=" + str(root / "no-bus"),
            DBUS_SYSTEM_BUS_ADDRESS="unix:path=" + str(root / "no-bus"), PIPEWIRE_REMOTE="macshell-no-audio",
            MACSHELL_TRANSLATION_CAPTURE=str(args.capture.resolve()) if args.capture else "")
        env.pop("LC_ALL", None)
        for key in tuple(env):
            if key.startswith("LC_") and key != "LC_MESSAGES":
                del env[key]
        logs = []
        for restart in (False, True):
            if restart:
                exported = subprocess.run([sys.executable, str(project / "scripts/session_locale.py")], env=env, capture_output=True, text=True, timeout=5, check=True)
                assignments = dict(line.split("=", 1) for line in exported.stdout.splitlines())
                assert assignments["LANG"].startswith("ru_") and assignments["LC_MESSAGES"].startswith("ru_")
                env.update(assignments, MACSHELL_LANGUAGE_RESTART="1")
                preference = root / "config/environment.d/90-macshell-locale.conf"
                assert preference.stat().st_mode & 0o777 == 0o600
            try:
                result = subprocess.run([quickshell(), "-p", str(shell)], env=env, capture_output=True, text=True, timeout=60)
                log = result.stdout + result.stderr
            except subprocess.TimeoutExpired as error:
                log = (error.stdout or b"").decode() + (error.stderr or b"").decode()
                result = subprocess.CompletedProcess([], 1)
            logs.append(log)
            Path("/tmp/macshell-system-language-native.log").write_text("\n".join(logs))
            for line in log.splitlines():
                if re.search(r"SYSTEM_LANGUAGE|TypeError|ReferenceError|Binding loop|Unable to assign", line):
                    print(line)
            marker = "MACSHELL_SYSTEM_LANGUAGE_RESTART_PASS" if restart else "MACSHELL_SYSTEM_LANGUAGE_NATIVE_PASS"
            if result.returncode or marker not in log or re.search(r"TypeError|ReferenceError|Binding loop|Unable to assign", log):
                raise SystemExit(result.returncode or 1)


if __name__ == "__main__":
    main()

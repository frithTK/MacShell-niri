#!/usr/bin/env python3
"""Click production notification cards with isolated preferences and unavailable buses."""
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
    with tempfile.TemporaryDirectory(prefix="macshell-notifications-native-") as directory:
        root = Path(directory)
        shell = root / "shell"
        shutil.copytree(project / "MacShell", shell)
        path = shell / "shell.qml"
        source = path.read_text().replace("import QtQuick\n", "import QtQuick\nimport QtTest\n", 1)
        source = source.replace("ShellRoot {", "ShellRoot {\n" + (project / "tests/notifications-native.qml").read_text(), 1)
        path.write_text(source)
        path = shell / "MacBar.qml"
        source = path.read_text().replace("    id: root\n", "    id: root\n    property var testUi: null\n    property alias testToasts: notifToasts\n    property alias testHistory: notifHist\n", 1)
        source = source.replace("                id: ui\n", "                id: ui\n                Component.onCompleted: root.testUi = ui\n", 1)
        path.write_text(source)
        for name in ("cache", "config", "settings/macbar", "settings/macdock"):
            (root / name).mkdir(parents=True)
        (root / "settings/macbar/settings.json").write_text(json.dumps(dict(
            barEnabled=False, spotlightEnabled=False, ccEnabled=False, notificationsEnabled=True,
            clipHistory=False, autoContrast=False, barGlass=False, statsMetrics=[])))
        (root / "settings/macdock/settings.json").write_text(json.dumps(dict(dockEnabled=False, windowCapture=False)))
        environment = dict(os.environ, QT_QPA_PLATFORM="wayland", QT_QPA_PLATFORMTHEME="", QT_QUICK_CONTROLS_STYLE="Basic",
            XDG_CACHE_HOME=str(root / "cache"), XDG_CONFIG_HOME=str(root / "config"), MACSHELL_SETTINGS_HOME=str(root / "settings"),
            NIRI_SOCKET=str(root / "no-session"), DBUS_SESSION_BUS_ADDRESS="unix:path=" + str(root / "no-bus"),
            DBUS_SYSTEM_BUS_ADDRESS="unix:path=" + str(root / "no-bus"))
        try:
            result = subprocess.run([quickshell(), "-p", str(shell)], env=environment, capture_output=True, text=True, timeout=25)
            log = result.stdout + result.stderr
        except subprocess.TimeoutExpired as error:
            log = (error.stdout or b"").decode() + (error.stderr or b"").decode()
            result = subprocess.CompletedProcess([], 1)
        Path("/tmp/macshell-notifications-native.log").write_text(log)
        for line in log.splitlines():
            if re.search(r"NOTIFICATIONS_NATIVE|TypeError|ReferenceError|Binding loop|Unable to assign", line):
                print(line)
        if result.returncode or "MACSHELL_NOTIFICATIONS_NATIVE_PASS" not in log or re.search(r"TypeError|ReferenceError|Binding loop|Unable to assign", log):
            raise SystemExit(result.returncode or 1)


if __name__ == "__main__":
    main()

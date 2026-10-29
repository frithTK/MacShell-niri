#!/usr/bin/env python3
"""Check the localization foundation in a real Calculator window with private settings."""
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
    with tempfile.TemporaryDirectory(prefix="macshell-translation-native-") as directory:
        root = Path(directory)
        shell = root / "shell"
        shutil.copytree(project / "MacShell", shell)
        path = shell / "shell.qml"
        source = path.read_text().replace("import QtQuick\n", "import QtQuick\nimport QtQuick.Window\n", 1)
        source = source.replace("ShellRoot {", "ShellRoot {\n" + (project / "tests/translation-native.qml").read_text(), 1)
        path.write_text(source)
        for name in ("cache", "config", "settings/macbar", "settings/macdock"):
            (root / name).mkdir(parents=True)
        (root / "settings/macbar/settings.json").write_text(json.dumps(dict(
            barEnabled=False, spotlightEnabled=False, ccEnabled=False, notificationsEnabled=False,
            clipHistory=False, autoContrast=False, barGlass=False, statsMetrics=[])))
        (root / "settings/macdock/settings.json").write_text(json.dumps(dict(dockEnabled=False, windowCapture=False)))
        environment = dict(os.environ, QT_QPA_PLATFORM="wayland", QT_QPA_PLATFORMTHEME="", QT_QUICK_CONTROLS_STYLE="Basic",
            XDG_CACHE_HOME=str(root / "cache"), XDG_CONFIG_HOME=str(root / "config"), MACSHELL_SETTINGS_HOME=str(root / "settings"),
            NIRI_SOCKET=str(root / "no-session"), DBUS_SESSION_BUS_ADDRESS="unix:path=" + str(root / "no-bus"),
            DBUS_SYSTEM_BUS_ADDRESS="unix:path=" + str(root / "no-bus"),
            MACSHELL_TRANSLATION_CAPTURE=str(args.capture.resolve()) if args.capture else "")
        try:
            result = subprocess.run([quickshell(), "-p", str(shell)], env=environment, capture_output=True, text=True, timeout=30)
            log = result.stdout + result.stderr
        except subprocess.TimeoutExpired as error:
            log = (error.stdout or b"").decode() + (error.stderr or b"").decode()
            result = subprocess.CompletedProcess([], 1)
        Path("/tmp/macshell-translation-native.log").write_text(log)
        for line in log.splitlines():
            if re.search(r"TRANSLATION_NATIVE|TypeError|ReferenceError|Binding loop|Unable to assign", line):
                print(line)
        if result.returncode or "MACSHELL_TRANSLATION_NATIVE_PASS" not in log or re.search(r"TypeError|ReferenceError|Binding loop|Unable to assign", log):
            raise SystemExit(result.returncode or 1)


if __name__ == "__main__":
    main()

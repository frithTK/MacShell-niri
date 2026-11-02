#!/usr/bin/env python3
"""Exercise the updates pane with a fake backend in a nested niri session."""
import argparse
import importlib.util
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
spec = importlib.util.spec_from_file_location("showcase", project / "scripts/capture-showcase.py")
show = importlib.util.module_from_spec(spec)
spec.loader.exec_module(show)
original_replace = show.replace
def compatible_replace(path, old, new):
    if old.startswith('text: "Sound · "') and old not in path.read_text():
        return
    return original_replace(path, old, new)
show.replace = compatible_replace

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--capture-dir", type=Path, default=Path("/tmp/macshell-updates-native-images"))
args = parser.parse_args()
args.capture_dir.mkdir(parents=True, exist_ok=True)

with tempfile.TemporaryDirectory(prefix="macshell-updates-test-") as directory:
    root = Path(directory)
    shell = show.prepare(root)
    (shell / "update_service.py").write_text((project / "tests/fixtures/updates_fixture.py").read_text())
    path = shell / "shell.qml"
    source = path.read_text().replace("import QtQuick\n", "import QtQuick\nimport QtQuick.Window\nimport QtTest\n", 1)
    path.write_text(source.replace("ShellRoot {", "ShellRoot {\n" + (project / "tests/updates-native.qml").read_text(), 1))
    path = shell / "MacDock.qml"
    path.write_text(path.read_text().replace("    id: root\n", "    id: root\n    function testWindow() { return prefsWindow; }\n", 1))
    environment = dict(os.environ, HOME=str(root / "home"), XDG_CONFIG_HOME=str(root / "config"), XDG_CACHE_HOME=str(root / "cache"),
        XDG_DATA_HOME=str(root / "data"), XDG_DATA_DIRS=str(root / "data"), MACSHELL_SETTINGS_HOME=str(root / "settings"),
        MACSHELL_NIRI_PROFILE=str(root / "niri"), QT_QPA_PLATFORMTHEME="", QT_QUICK_CONTROLS_STYLE="Basic", QT_QPA_PLATFORM="wayland",
        DBUS_SESSION_BUS_ADDRESS="unix:path=" + str(root / "no-bus"), DBUS_SYSTEM_BUS_ADDRESS="unix:path=" + str(root / "no-bus"),
        PIPEWIRE_REMOTE="macshell-updates-no-audio", PULSE_SERVER="unix:" + str(root / "no-pulse"),
        MACSHELL_SHOWCASE_DARK_WALL=str(project / "docs/showcase/wallpaper-dark.svg"),
        MACSHELL_SHOWCASE_LIGHT_WALL=str(project / "docs/showcase/wallpaper.svg"),
        MACSHELL_SHOWCASE_ART=(project / "docs/showcase/album.svg").as_uri(),
        MACSHELL_UPDATES_CAPTURE=str(args.capture_dir.resolve()))
    nested = client = None
    log_path = Path("/tmp/macshell-updates-native.log")
    with log_path.open("w") as log:
        try:
            nested = subprocess.Popen(["niri", "--config", str(root / "niri/config.kdl"), "--", sys.executable, str(root / "child.py")], env=environment, stdout=log, stderr=log)
            deadline = time.monotonic() + 15
            while not (root / "nested.json").exists():
                if nested.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("Nested compositor did not start")
                time.sleep(.1)
            environment.update(json.loads((root / "nested.json").read_text()))
            client = subprocess.Popen([show.quickshell(), "-p", str(shell)], env=environment, stdout=log, stderr=log)
            result = client.wait(timeout=50)
            log.flush()
            text = log_path.read_text()
            for line in text.splitlines():
                if re.search(r"UPDATES_NATIVE|TypeError|ReferenceError|Binding loop|Unable to assign", line):
                    print(line)
            if result or "MACSHELL_UPDATES_NATIVE_PASS" not in text or re.search(r"TypeError|ReferenceError|Binding loop|Unable to assign", text):
                raise RuntimeError("Updates UI check failed; see " + str(log_path))
        finally:
            show.stop(client); show.stop(nested)

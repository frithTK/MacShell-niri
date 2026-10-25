#!/usr/bin/env python3
"""Check the separate session before its compositor is started."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def check(config, binary):
    subprocess.run(["niri", "validate", "-c", str(config)], check=True, capture_output=True, text=True, timeout=10)
    check_runtime(binary)
    print("MacShell session configuration and Quickshell runtime are ready.")


def check_runtime(binary):
    with tempfile.TemporaryDirectory(prefix="macshell-session-check-") as temporary:
        directory = Path(temporary)
        (directory / "runtime").mkdir(mode=0o700)
        probe = directory / "shell.qml"
        probe.write_text('import QtQuick\nimport Quickshell\nShellRoot { Timer { interval: 100; running: true; onTriggered: Qt.quit() } }\n')
        # SDDM has no compositor yet. A GTK platform theme can try to open a
        # display (or activate a portal) even with the offscreen QPA plugin.
        env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_QPA_PLATFORMTHEME="",
                   QT_QUICK_CONTROLS_STYLE="Basic", XDG_RUNTIME_DIR=str(directory / "runtime"),
                   XDG_CACHE_HOME=temporary, DBUS_SESSION_BUS_ADDRESS="unix:path=" + temporary + "/no-bus")
        for key in ("DISPLAY", "WAYLAND_DISPLAY"):
            env.pop(key, None)
        result = subprocess.run([str(binary), "-p", str(probe)], env=env, capture_output=True, text=True, timeout=10)
        log = result.stdout + result.stderr
        if result.returncode or "without rebuilding" in log or "Failed to load configuration" in log:
            raise RuntimeError("Quickshell runtime check failed:\n" + log)


if __name__ == "__main__":
    try:
        check(Path(sys.argv[1]), Path(sys.argv[2]))
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)

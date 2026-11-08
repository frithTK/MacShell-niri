import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which("qs"), "Quickshell is required")
class JsonServiceSessionTests(unittest.TestCase):
    def test_serialization_is_opt_in_and_disconnect_releases_busy(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "runtime").mkdir(mode=0o700)
            shutil.copy(ROOT / "MacShell/JsonService.qml", root / "JsonService.qml")
            helper = root / "helper.py"
            helper.write_text('import json,sys,time\nprint(json.dumps({"type":"ready"}),flush=True)\nfor line in sys.stdin:\n time.sleep(.2)\n')
            (root / "shell.qml").write_text('''import QtQuick
import Quickshell
ShellRoot {
    JsonService { id: ordinary; script: "%s"; onConnected: {
        if (send("one", {}) < 1 || send("two", {}) < 1) Qt.exit(2);
    } }
    JsonService { id: serial; script: "%s"; serializeRequests: true; onConnected: {
        if (send("one", {}) < 1 || send("two", {}) !== -2) Qt.exit(3);
        enabled = false;
    } }
    Timer { interval: 600; running: true; onTriggered: {
        if (serial.busy || !serial.lastError) Qt.exit(4); else Qt.exit(0);
    } }
    Timer { interval: 4000; running: true; onTriggered: Qt.exit(5) }
}
''' % (helper, helper))
            env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_QPA_PLATFORMTHEME="", QT_QUICK_CONTROLS_STYLE="Basic", XDG_RUNTIME_DIR=str(root / "runtime"), XDG_CACHE_HOME=directory, DBUS_SESSION_BUS_ADDRESS="unix:path=" + str(root / "no-bus"))
            env.pop("WAYLAND_DISPLAY", None)
            env.pop("DISPLAY", None)
            result = subprocess.run([shutil.which("qs"), "-p", directory], env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()

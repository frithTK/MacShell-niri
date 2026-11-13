import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]

MATCH = r'''#!/bin/sh
printf '%s\n' '{"type":"status","code":"checking"}'
printf '%s\n' '{"type":"device","scanType":"swipe"}'
printf '%s\n' '{"type":"status","code":"scan","stage":0,"total":5}'
sleep 0.2
printf '%s\n' '{"type":"status","code":"verify-no-match","stage":1,"total":5}'
printf '%s\n' '{"type":"status","code":"scan","stage":1,"total":5}'
sleep 0.2
printf '%s\n' '{"type":"status","code":"verify-swipe-too-short","stage":1,"total":5}'
sleep 0.2
printf '%s\n' '{"type":"result","success":true,"code":"verify-match"}'
'''

LOCKOUT = r'''#!/bin/sh
printf '%s\n' '{"type":"device","scanType":"press"}'
printf '%s\n' '{"type":"status","code":"scan","stage":0,"total":5}'
for n in 1 2 3 4 5; do
  printf '{"type":"status","code":"verify-no-match","stage":%s,"total":5}\n' "$n"
done
printf '%s\n' '{"type":"result","success":false,"code":"too_many_attempts"}'
'''

FLAKY = r'''#!/bin/sh
count_file="$(dirname "$0")/flaky-count"
n=$(cat "$count_file" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s' "$n" > "$count_file"
if [ "$n" -lt 2 ]; then
  printf '%s\n' '{"type":"result","success":false,"code":"service_error"}'
  exit 0
fi
printf '%s\n' '{"type":"status","code":"scan","stage":0,"total":5}'
sleep 30
'''

SHELL = r'''import QtQuick
import Quickshell
ShellRoot {
    property int rejections: 0
    property bool matchedOnce: false
    property bool exhaustedOnce: false
    property bool hintSeen: false
    FingerprintUnlock {
        id: match; launcher: "%(match)s"; active: true
        onRejected: rejections++
        onMatched: matchedOnce = true
        onHintChanged: if (hint === "verify-swipe-too-short") hintSeen = true
    }
    FingerprintUnlock {
        id: lockout; launcher: "%(lockout)s"; active: true
        onExhausted: exhaustedOnce = true
    }
    FingerprintUnlock { id: flaky; launcher: "%(flaky)s"; active: true }
    FingerprintUnlock { id: inactive; launcher: "%(match)s"; active: false }
    Timer {
        interval: 200; repeat: true; running: true
        onTriggered: {
            if (!matchedOnce || !exhaustedOnce || !flaky.listening) return;
            if (rejections !== 1 || !hintSeen || match.scanType !== "swipe" || match.phase !== "matched") Qt.exit(2);
            if (!lockout.lockedOut || lockout.attempts !== 5 || lockout.scanType !== "press" || lockout.listening) Qt.exit(3);
            if (inactive.phase !== "off") Qt.exit(4);
            lockout.active = false; lockout.active = true;
            if (lockout.phase !== "locked_out") Qt.exit(5);
            flaky.active = false;
            Qt.exit(0);
        }
    }
    Timer { interval: 9000; running: true; onTriggered: Qt.exit(6) }
}
'''


@unittest.skipUnless(shutil.which("qs"), "Quickshell is required")
class FingerprintUnlockTests(unittest.TestCase):
    def test_match_retry_lockout_and_backoff(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "runtime").mkdir(mode=0o700)
            shutil.copy(ROOT / "MacLock/FingerprintUnlock.qml", root / "FingerprintUnlock.qml")
            scripts = {}
            for name, body in (("match", MATCH), ("lockout", LOCKOUT), ("flaky", FLAKY)):
                path = root / (name + ".sh")
                path.write_text(body)
                scripts[name] = str(path)
            (root / "shell.qml").write_text(SHELL % scripts)
            env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_QPA_PLATFORMTHEME="", QT_QUICK_CONTROLS_STYLE="Basic",
                       XDG_RUNTIME_DIR=str(root / "runtime"), XDG_CACHE_HOME=directory,
                       DBUS_SESSION_BUS_ADDRESS="unix:path=" + str(root / "no-bus"))
            env.pop("WAYLAND_DISPLAY", None)
            env.pop("DISPLAY", None)
            result = subprocess.run([shutil.which("qs"), "-p", directory], env=env, capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


class FingerprintUnlockLauncherTests(unittest.TestCase):
    def test_launcher_requires_the_unlock_protocol(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            launcher = root / "fingerprint-unlock.sh"
            launcher.write_text((ROOT / "MacLock/fingerprint-unlock.sh").read_text())
            binary = root / "fingerprint-operation-rust"
            binary.write_text("#!/bin/sh\nif [ \"${1-}\" = --unlock-protocol-version ]; then echo 'macshell-fingerprint-unlock 1'; else echo rust \"$@\"; fi\n")
            binary.chmod(0o755)
            ok = subprocess.run(["/bin/sh", str(launcher)], capture_output=True, text=True, timeout=10)
            self.assertEqual(ok.stdout.strip(), "rust unlock")
            binary.write_text("#!/bin/sh\necho 'macshell-fingerprint-operation 1'\n")
            old = subprocess.run(["/bin/sh", str(launcher)], capture_output=True, text=True, timeout=10)
            self.assertNotEqual(old.returncode, 0)
            self.assertIn("Rust", old.stderr)


if __name__ == "__main__":
    unittest.main()

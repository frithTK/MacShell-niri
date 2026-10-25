"""Real FileView polling against temporary sysfs-shaped files, never hardware."""
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, str(Path(__file__).parents[1]))
from scripts.install_niri import quickshell


@unittest.skipUnless(shutil.which(quickshell()), 'Quickshell is required')
class BrightnessNativeTests(unittest.TestCase):
    def test_external_changes_maximum_and_device_return_without_recurring_processes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = Path(__file__).parents[1] / 'MacShell'
            for name in ('BrightnessControl.qml', 'BrightnessValue.js'):
                shutil.copyfile(source / name, root / name)
            device = root / 'sysfs/backlight/fixture'
            device.mkdir(parents=True)
            (device / 'brightness').write_text('100\n')
            (device / 'max_brightness').write_text('200\n')
            probe = root / 'discover.py'
            probe.write_text('''import os
from pathlib import Path
root = Path(os.environ['TEST_ROOT'])
with (root / 'calls').open('a') as log: log.write('discovery\\n')
device = root / 'sysfs/backlight/fixture'
current, maximum = [(device / name).read_text().strip() for name in ('brightness', 'max_brightness')]
print('fixture,backlight,' + current + ',50%,' + maximum)
''')
            (root / 'shell.qml').write_text('''import QtQuick
import Quickshell
ShellRoot {
    BrightnessControl {
        id: monitor
        sysfsRoot: Quickshell.env("TEST_ROOT") + "/sysfs"
        discoveryCommand: ''' + json.dumps([sys.executable, str(probe)]) + '''
    }
    Timer {
        interval: 50; repeat: true; running: true
        property string previous: ""
        onTriggered: {
            var current = monitor.available ? "ready:" + monitor.value : "missing";
            if (current !== previous) { previous = current; console.log("BRIGHTNESS_TEST " + current); }
        }
    }
}
''')
            for name in ('runtime', 'cache', 'config'):
                (root / name).mkdir()
            (root / 'runtime').chmod(0o700)
            environment = dict(os.environ, TEST_ROOT=str(root), QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='',
                XDG_RUNTIME_DIR=str(root / 'runtime'), XDG_CACHE_HOME=str(root / 'cache'), XDG_CONFIG_HOME=str(root / 'config'),
                DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'))
            process = subprocess.Popen([quickshell(), '-p', str(root)], env=environment,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            messages, history = queue.Queue(), []
            def read():
                for line in process.stdout:
                    messages.put(line.rstrip())
            reader = threading.Thread(target=read, daemon=True)
            reader.start()
            def wait(text, timeout=4):
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    try:
                        line = messages.get(timeout=.1)
                    except queue.Empty:
                        if process.poll() is not None:
                            break
                        continue
                    history.append(line)
                    if 'BRIGHTNESS_TEST ' + text in line:
                        return
                self.fail('No brightness state ' + text + ': ' + repr(history[-12:]))
            try:
                wait('ready:0.5')
                (device / 'brightness').write_text('90\n')
                wait('ready:0.45')
                (device / 'max_brightness').write_text('300\n')
                wait('ready:0.3')
                self.assertEqual((root / 'calls').read_text().splitlines(), ['discovery'])
                (device / 'brightness').unlink()
                wait('missing')
                (device / 'brightness').write_text('60\n')
                wait('ready:0.2', timeout=7)
                self.assertEqual(len((root / 'calls').read_text().splitlines()), 2)
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                reader.join(timeout=2)
                process.stdout.close()

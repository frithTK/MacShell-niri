#!/usr/bin/env python3
"""Real notify-send and closed-window scheduling on a private session bus."""
import json
import os
from pathlib import Path
import queue
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import uuid

from gi.repository import Gio, GLib

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from scripts.install_niri import quickshell
from tests.service_launchers import copy_macshell_with_python_launchers

XML = '''<node><interface name="org.freedesktop.Notifications">
<method name="GetCapabilities"><arg type="as" direction="out"/></method>
<method name="GetServerInformation"><arg type="s" direction="out"/><arg type="s" direction="out"/><arg type="s" direction="out"/><arg type="s" direction="out"/></method>
<method name="Notify"><arg type="s" direction="in"/><arg type="u" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="as" direction="in"/><arg type="a{sv}" direction="in"/><arg type="i" direction="in"/><arg type="u" direction="out"/></method>
</interface></node>'''


class FakeNotifications:
    def __init__(self):
        self.calls = queue.Queue()
        self.bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        self.bus.register_object('/org/freedesktop/Notifications', Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0], self.method, None, None)
        self.bus.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'RequestName',
                           GLib.Variant('(su)', ('org.freedesktop.Notifications', 0)), None, Gio.DBusCallFlags.NONE, 3000, None)

    def method(self, _conn, _sender, _path, _interface, method, args, invocation):
        if method == 'GetCapabilities': invocation.return_value(GLib.Variant('(as)', ([],))); return
        if method == 'GetServerInformation': invocation.return_value(GLib.Variant('(ssss)', ('Test', 'MacShell', '1', '1.2'))); return
        if method == 'Notify':
            self.calls.put(args.unpack())
            invocation.return_value(GLib.Variant('(u)', (1,)))
            return
        invocation.return_dbus_error('org.freedesktop.DBus.Error.UnknownMethod', method)


def main():
    if not os.environ.get('DBUS_SESSION_BUS_ADDRESS') or os.environ['DBUS_SESSION_BUS_ADDRESS'] == os.environ.get('MACSHELL_TEST_PARENT_BUS'):
        raise RuntimeError('A separate private D-Bus session is required')
    fixture = FakeNotifications(); loop = GLib.MainLoop()
    thread = threading.Thread(target=loop.run, daemon=True); thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='macshell-reminder-dbus-') as directory:
            root = Path(directory)
            for name in ('home', 'cache', 'config', 'data', 'runtime'): (root / name).mkdir()
            (root / 'runtime').chmod(0o700)
            env = dict(os.environ, HOME=str(root / 'home'), XDG_CONFIG_HOME=str(root / 'config'), XDG_CACHE_HOME=str(root / 'cache'),
                       XDG_RUNTIME_DIR=str(root / 'runtime'), XDG_DATA_HOME=str(root / 'data'),
                       MACSHELL_REMINDERS_DATA_HOME=str(root / 'data'), QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='',
                       QT_QUICK_CONTROLS_STYLE='Basic', NIRI_SOCKET=str(root / 'no-niri'))
            env.pop('DISPLAY', None); env.pop('WAYLAND_DISPLAY', None)
            config = str(copy_macshell_with_python_launchers(ROOT / 'MacShell', root / 'shell') / 'reminders-standalone.qml')
            store = root / 'data/macshell/reminders/tasks.sqlite3'
            process = None
            def ipc(method):
                return subprocess.run([quickshell(), '-p', config, 'ipc', 'call', 'remindersPreview', method],
                                      env=env, capture_output=True, text=True, timeout=3)
            def start():
                child = subprocess.Popen([quickshell(), '-p', config], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline and child.poll() is None:
                    result = ipc('state')
                    if result.returncode == 0:
                        try: state = json.loads(result.stdout)
                        except ValueError: state = {}
                        if state.get('ready') and state.get('visible') and not state.get('busy'): return child
                    time.sleep(.1)
                child.terminate(); child.wait(timeout=5)
                raise RuntimeError('Standalone reminder window did not start')
            def wait_hidden():
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    result = ipc('state')
                    if result.returncode == 0 and not json.loads(result.stdout)['visible']: return
                    time.sleep(.1)
                raise RuntimeError('Reminder window did not close')
            try:
                process = start()
                task_id = str(uuid.uuid4()); now = time.time_ns() // 1000000
                with sqlite3.connect(store) as db:
                    db.execute("INSERT INTO tasks(id,list_id,title,revision,updated,due_at,alert_state) VALUES(?, 'inbox', ?, 0, ?, ?, 'pending')",
                               (task_id, 'Тестовое напоминание', now, now + 1500))
                if ipc('close').returncode: raise RuntimeError('Could not close test window')
                wait_hidden()
                call = fixture.calls.get(timeout=8)
                assert call[3] == 'Тестовое напоминание', call
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    with sqlite3.connect(store) as db: state = db.execute('SELECT alert_state FROM tasks WHERE id=?', (task_id,)).fetchone()[0]
                    if state == 'delivered': break
                    time.sleep(.1)
                assert state == 'delivered', state
                if ipc('shutdown').returncode: raise RuntimeError('Could not stop test preview')
                process.wait(timeout=5); process = None
                process = start()
                time.sleep(2.5)
                assert fixture.calls.empty(), 'Previously delivered reminder was repeated after restart'
                if ipc('close').returncode: raise RuntimeError('Could not close restarted window')
                wait_hidden()
                if ipc('shutdown').returncode: raise RuntimeError('Could not stop restarted preview')
                process.wait(timeout=5); process = None
                print('REMINDERS_DBUS_PASS: private D-Bus, closed window, real notify-send, no duplicate after restart')
            finally:
                if process and process.poll() is None: process.terminate(); process.wait(timeout=5)
    finally:
        loop.quit(); thread.join(timeout=5)


if __name__ == '__main__': main()

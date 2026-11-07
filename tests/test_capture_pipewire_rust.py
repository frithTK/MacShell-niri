"""PipeWire integration using a private daemon and synthetic video only."""
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
from urllib.parse import unquote, urlparse

from gi.repository import Gio, GLib

BINARY = os.environ.get('MACSHELL_TEST_CAPTURE_PIPEWIRE_HARNESS')
SERVICE = os.environ.get('MACSHELL_TEST_CAPTURE_SERVICE_BINARY')
TOOLS = all(shutil.which(v) for v in ('pipewire', 'pw-dump', 'gst-launch-1.0', 'wireplumber', 'dbus-daemon'))


@unittest.skipUnless(BINARY and TOOLS, 'Capture harness and PipeWire/GStreamer required')
class PrivatePipeWireTests(unittest.TestCase):
    def test_synthetic_video_through_private_pipewire(self):
        with tempfile.TemporaryDirectory(prefix='macshell-private-pipewire-') as temp:
            root = Path(temp)
            runtime = root / 'runtime'
            runtime.mkdir(mode=0o700)
            env = dict(os.environ, HOME=str(root), XDG_RUNTIME_DIR=str(runtime),
                       PIPEWIRE_RUNTIME_DIR=str(runtime), PIPEWIRE_REMOTE='pipewire-0',
                       XDG_CONFIG_HOME=str(root / 'config'), XDG_STATE_HOME=str(root / 'state'),
                       XDG_CACHE_HOME=str(root / 'cache'))
            for key in ('PIPEWIRE_CONFIG_DIR', 'PIPEWIRE_CONFIG_NAME', 'DISPLAY', 'WAYLAND_DISPLAY'):
                env.pop(key, None)
            config = root / 'bus.conf'
            config.write_text('<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">'
                '<busconfig><type>session</type><listen>unix:tmpdir=' + str(root) + '</listen>'
                '<auth>EXTERNAL</auth><policy context="default"><allow own="*"/><allow send_destination="*"/><allow receive_sender="*"/></policy></busconfig>')
            dbus = subprocess.Popen(['dbus-daemon', '--config-file=' + str(config), '--nofork', '--print-address=1'],
                                    env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            env['DBUS_SESSION_BUS_ADDRESS'] = dbus.stdout.readline().strip()
            env['DBUS_SYSTEM_BUS_ADDRESS'] = env['DBUS_SESSION_BUS_ADDRESS']
            daemon = subprocess.Popen(['pipewire'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            producer = manager = None
            try:
                deadline = time.monotonic() + 5
                while not (runtime / 'pipewire-0').exists() and daemon.poll() is None and time.monotonic() < deadline:
                    time.sleep(.02)
                self.assertTrue((runtime / 'pipewire-0').exists(), 'Private PipeWire daemon did not start')
                # The policy-only profile does not load audio, Bluetooth or camera monitors.
                manager = subprocess.Popen(['wireplumber', '-p', 'policy'], env=env,
                                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                producer = subprocess.Popen(['gst-launch-1.0', '-q', 'videotestsrc', 'is-live=true', '!',
                    'videoconvert', '!', 'video/x-raw,format=BGRA,width=320,height=240,framerate=15/1', '!',
                    'pipewiresink', 'stream-properties=props,node.name=(string)macshell-capture-test,media.class=(string)Video/Source'],
                    env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                node = None
                deadline = time.monotonic() + 8
                while node is None and producer.poll() is None and time.monotonic() < deadline:
                    dump = subprocess.run(['pw-dump'], env=env, capture_output=True, text=True, timeout=3)
                    if dump.returncode == 0:
                        for obj in json.loads(dump.stdout):
                            props = obj.get('info', {}).get('props', {})
                            if props.get('node.name') == 'macshell-capture-test':
                                node = obj['id']
                    time.sleep(.05)
                self.assertIsNotNone(node, 'Synthetic PipeWire producer did not create its node')
                if SERVICE:
                    self.check_service(env, node, runtime)
                else:
                    result = subprocess.run([BINARY, str(node)], env=env, capture_output=True, text=True, timeout=12)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    width, height, size = map(int, result.stdout.split())
                    self.assertGreater(size, 8)
                    self.assertTrue(0 < width <= 160 and 0 < height <= 160)
            finally:
                for process in (producer, manager, daemon, dbus):
                    if process is not None:
                        if process.poll() is None: process.terminate()
                        try: process.wait(timeout=3)
                        except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=3)
                        if process.stderr: process.stderr.close()
                        if process.stdout: process.stdout.close()

    def check_service(self, env, node, runtime):
        env = dict(env, GST_DEBUG='2', GST_DEBUG_NO_COLOR='1', GST_DEBUG_FILE=str(runtime / 'gst-debug.log'))
        bus = Gio.DBusConnection.new_for_address_sync(env['DBUS_SESSION_BUS_ADDRESS'],
            Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
        name = 'org.gnome.Mutter.ScreenCast'
        root = '/org/gnome/Mutter/ScreenCast'
        session = root + '/Session/u1'
        stream = root + '/Stream/u1'
        bus.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'RequestName',
                      GLib.Variant('(su)', (name, 0)), None, Gio.DBusCallFlags.NONE, 1000, None)
        stops = []
        def method(connection, sender, path, interface, method_name, parameters, invocation):
            if method_name == 'CreateSession': invocation.return_value(GLib.Variant('(o)', (session,)))
            elif method_name == 'RecordWindow': invocation.return_value(GLib.Variant('(o)', (stream,)))
            elif method_name == 'Start':
                invocation.return_value(None)
                connection.emit_signal(None, stream, name + '.Stream', 'PipeWireStreamAdded', GLib.Variant('(u)', (node,)))
            elif method_name == 'Stop': stops.append(True); invocation.return_value(None)
        ids = []
        def register(path, interface, xml):
            info = Gio.DBusNodeInfo.new_for_xml('<node><interface name="' + interface + '">' + xml + '</interface></node>').interfaces[0]
            ids.append(bus.register_object(path, info, method, None, None))
        register(root, name, '<method name="CreateSession"><arg type="a{sv}" direction="in"/><arg type="o" direction="out"/></method>')
        register(session, name + '.Session', '<method name="RecordWindow"><arg type="a{sv}" direction="in"/><arg type="o" direction="out"/></method><method name="Start"/><method name="Stop"/>')
        register(stream, name + '.Stream', '<signal name="PipeWireStreamAdded"><arg type="u"/></signal>')
        loop = GLib.MainLoop()
        thread = threading.Thread(target=loop.run, daemon=True)
        thread.start()
        service = subprocess.Popen([SERVICE], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        messages = queue.Queue()
        def read():
            for line in service.stdout: messages.put(json.loads(line))
        reader = threading.Thread(target=read, daemon=True)
        reader.start()
        try:
            service.stdin.write('{"id":123}\n'); service.stdin.flush()
            deadline = time.monotonic() + 8
            event = None
            while time.monotonic() < deadline:
                try: event = messages.get(timeout=.2)
                except queue.Empty: continue
                if event.get('id') == 123: break
            self.assertIsNotNone(event, 'No preview event from synthetic service')
            diagnostic = (runtime / 'gst-debug.log').read_text() if (runtime / 'gst-debug.log').exists() else ''
            self.assertNotIn('error', event, repr(event) + '\n' + diagnostic[-8000:])
            path = Path(unquote(urlparse(event['url']).path))
            self.assertTrue(path.is_relative_to(runtime))
            self.assertTrue(path.read_bytes().startswith(b'\x89PNG\r\n\x1a\n'))
        finally:
            service.stdin.close()
            try: service.wait(timeout=6)
            except subprocess.TimeoutExpired: service.kill(); service.wait(timeout=3)
            reader.join(timeout=2)
            error = service.stderr.read()
            service.stdout.close(); service.stderr.close()
            loop.quit(); thread.join(timeout=2)
            for identity in ids: bus.unregister_object(identity)
            bus.close_sync(None)
        self.assertEqual(service.returncode, 0, error)
        self.assertEqual(len(stops), 1)
        self.assertFalse(path.exists())


if __name__ == '__main__':
    unittest.main()

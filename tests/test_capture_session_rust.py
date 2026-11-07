"""Native ScreenCast control against a private synthetic session bus."""
import os
import time
import unittest
from gi.repository import Gio, GLib
from test_dbus_protocol import PrivateBus
from test_network_agent_rust import Harness

BINARY = os.environ.get('MACSHELL_TEST_CAPTURE_SESSION_HARNESS')
BUS = 'org.gnome.Mutter.ScreenCast'
ROOT = '/org/gnome/Mutter/ScreenCast'
SESSION = BUS + '.Session'
STREAM = BUS + '.Stream'
SESSION_PATH = ROOT + '/Session/u1'
STREAM_PATH = ROOT + '/Stream/u1'


class CaptureBus(PrivateBus):
    def __init__(self):
        self.calls = []
        self.mode = 'normal'
        self.stops = 0
        super().__init__()
        self.connection.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'RequestName',
                                  GLib.Variant('(su)', (BUS, 0)), None, Gio.DBusCallFlags.NONE, 1000, None)
        self.register(ROOT, BUS, '<method name="CreateSession"><arg type="a{sv}" direction="in"/><arg type="o" direction="out"/></method>')
        self.register(SESSION_PATH, SESSION, '<method name="RecordWindow"><arg type="a{sv}" direction="in"/><arg type="o" direction="out"/></method><method name="Start"/><method name="Stop"/>')
        self.register(STREAM_PATH, STREAM, '<signal name="PipeWireStreamAdded"><arg type="u"/></signal>')

    def method(self, bus, sender, path, iface, method, parameters, invocation):
        if iface == BUS and method == 'CreateSession':
            self.calls.append((method, parameters.unpack()))
            invocation.return_value(GLib.Variant('(o)', ('/foreign' if self.mode == 'foreign_session' else SESSION_PATH,)))
        elif iface == SESSION and method == 'RecordWindow':
            self.calls.append((method, parameters.unpack()))
            if self.mode == 'record_error':
                invocation.return_dbus_error(BUS + '.Error.Failed', 'synthetic')
            else:
                invocation.return_value(GLib.Variant('(o)', ('/foreign' if self.mode == 'foreign_stream' else STREAM_PATH,)))
        elif iface == SESSION and method == 'Start':
            self.calls.append((method, parameters.unpack()))
            if self.mode == 'start_error':
                invocation.return_dbus_error(BUS + '.Error.Failed', 'synthetic')
            else:
                invocation.return_value(None)
                self.signal_node(42)
        elif iface == SESSION and method == 'Stop':
            self.stops += 1
            invocation.return_value(None)
        else:
            super().method(bus, sender, path, iface, method, parameters, invocation)

    def signal_node(self, node):
        self.connection.emit_signal(None, STREAM_PATH, STREAM, 'PipeWireStreamAdded', GLib.Variant('(u)', (node,)))


@unittest.skipUnless(BINARY, 'Set MACSHELL_TEST_CAPTURE_SESSION_HARNESS')
class CaptureSessionTests(unittest.TestCase):
    def setUp(self):
        self.bus = CaptureBus()
        self.harness = Harness(self.bus.address, binary=BINARY, environment={'DBUS_SESSION_BUS_ADDRESS': self.bus.address})

    def tearDown(self):
        try: self.harness.close()
        finally: self.bus.close()

    def begin(self):
        self.harness.send('start', window=123, token=9)

    def test_exact_window_cursor_hidden_and_cleanup(self):
        self.begin()
        self.harness.wait('started')
        node = self.harness.wait('node')
        self.assertEqual((node['token'], node['node']), (9, 42))
        self.assertEqual(self.bus.calls[1][1], ({'window-id': 123, 'cursor-mode': 0},))
        self.harness.send('stop')
        self.harness.wait('stopped')
        self.assertEqual(self.bus.stops, 1)
        self.bus.signal_node(55)
        time.sleep(.05)
        self.assertFalse(any(v.get('type') == 'changed' for v in self.harness.seen))

    def test_changed_node_and_owner_loss_are_signaled(self):
        self.begin(); self.harness.wait('started'); self.harness.wait('node')
        self.bus.signal_node(55)
        self.assertEqual(self.harness.wait('changed')['token'], 9)
        self.bus.connection.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'ReleaseName',
                                      GLib.Variant('(s)', (BUS,)), None, Gio.DBusCallFlags.NONE, 1000, None)
        self.assertEqual(self.harness.wait('lost')['token'], 9)

    def test_foreign_sender_cannot_inject_stream_node(self):
        self.begin(); self.harness.wait('started'); self.harness.wait('node')
        attacker = Gio.DBusConnection.new_for_address_sync(self.bus.address,
            Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
        try:
            attacker.emit_signal(None, STREAM_PATH, STREAM, 'PipeWireStreamAdded', GLib.Variant('(u)', (55,)))
            time.sleep(.15)
            self.assertTrue(self.harness.queue.empty())
            self.bus.signal_node(66)
            self.assertEqual(self.harness.wait('changed')['token'], 9)
        finally:
            attacker.close_sync(None)

    def test_failures_stop_only_created_session(self):
        for mode, stops in [('foreign_session', 0), ('record_error', 1), ('foreign_stream', 2), ('start_error', 3)]:
            self.bus.mode = mode
            self.begin()
            self.harness.wait('error')
            self.assertEqual(self.bus.stops, stops)

    def test_rejects_zero_window_without_opening_session(self):
        self.harness.send('start', window=0, token=1)
        self.harness.wait('error')
        self.assertEqual(self.bus.calls, [])


if __name__ == '__main__':
    unittest.main()

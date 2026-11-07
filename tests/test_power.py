"""Power profile operations on a private D-Bus, without changing host power."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).parents[1] / 'MacShell'))
from gi.repository import Gio, GLib
import power_control as power
from test_dbus_protocol import PrivateBus, Client


class PowerBus(PrivateBus):
    def __init__(self, legacy=False):
        super().__init__()
        self.name, self.path = power.LEGACY if legacy else power.CURRENT
        self.connection.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus',
                                  'RequestName', GLib.Variant('(su)', (self.name, 0)), None, Gio.DBusCallFlags.NONE, 1000, None)
        self.reject = False
        self.ignore_set = False
        self.reject_release = False
        self.previous = None
        self.cookie = None
        self.calls = []
        self.register(self.path, self.name,
                      '<method name="HoldProfile"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="u" direction="out"/></method>'
                      '<method name="ReleaseProfile"><arg type="u" direction="in"/></method>',
                      {'ActiveProfile': ('s', 'balanced'), 'Profiles': ('aa{sv}', [
                          {'Profile': GLib.Variant('s', p)} for p in ['power-saver', 'balanced', 'performance']]),
                       'PerformanceInhibited': ('s', ''), 'PerformanceDegraded': ('s', '')})

    def register(self, path, interface, methods, properties=None):
        if not hasattr(self, 'name') or interface != self.name:
            return super().register(path, interface, methods, properties)
        self.props[(path, interface)] = {k: GLib.Variant(sig, v) for k, (sig, v) in properties.items()}
        xml = '<node><interface name="' + interface + '">' + methods + ''.join(
            '<property name="' + key + '" type="' + sig + '" access="readwrite"/>' for key, (sig, value) in properties.items()) + '</interface></node>'
        def get(bus, sender, path, iface, name):
            return self.props[(path, iface)][name]
        def set_prop(bus, sender, path, iface, name, value):
            if self.reject:
                return False
            if self.ignore_set:
                return True
            self.props[(path, iface)][name] = value
            self.changed()
            return True
        self.ids.append(self.connection.register_object(path, Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0], self.method, get, set_prop))

    def changed(self):
        self.connection.emit_signal(None, self.path, power.PROPS, 'PropertiesChanged',
                                    GLib.Variant('(sa{sv}as)', (self.name, self.props[(self.path, self.name)], [])))

    def set_active(self, value):
        self.props[(self.path, self.name)]['ActiveProfile'] = GLib.Variant('s', value)
        self.changed()

    def method(self, bus, sender, path, iface, method, parameters, invocation):
        if not hasattr(self, 'name') or iface != self.name:
            return super().method(bus, sender, path, iface, method, parameters, invocation)
        self.calls.append(method)
        if method == 'HoldProfile':
            self.previous = self.props[(path, iface)]['ActiveProfile'].unpack()
            self.cookie = 42
            self.set_active(parameters.unpack()[0])
            invocation.return_value(GLib.Variant('(u)', (self.cookie,)))
        elif method == 'ReleaseProfile':
            if self.reject_release:
                invocation.return_dbus_error('org.freedesktop.DBus.Error.Failed', 'Release failed')
                return
            if parameters.unpack()[0] != self.cookie:
                invocation.return_dbus_error('org.freedesktop.DBus.Error.InvalidArgs', 'Wrong hold')
                return
            self.cookie = None
            self.set_active(self.previous)
            invocation.return_value(None)


class PowerTests(unittest.TestCase):
    def setUp(self):
        self.bus = PowerBus()
        self.client = Client('power_control.py', self.bus.address)
        self.client.wait(lambda m: m.get('type') == 'state' and m.get('profile') == 'balanced')

    def tearDown(self):
        self.client.close()
        self.bus.close()

    def state(self, profile=None, **expected):
        return self.client.wait(lambda m: m.get('type') == 'state' and not m.get('busy')
                                and (profile is None or m.get('profile') == profile)
                                and all(m.get(k) == v for k, v in expected.items()))

    def test_confirmed_selection_and_external_changes(self):
        self.client.send('select', profile='power-saver')
        self.state('power-saver')
        self.bus.set_active('performance')
        self.state('performance')

    def test_failed_write_preserves_actual_profile(self):
        self.bus.reject = True
        self.client.send('select', profile='performance')
        state = self.client.wait(lambda m: m.get('type') == 'state' and m.get('error') and not m.get('busy'))
        self.assertEqual(state['profile'], 'balanced')

    def test_unsupported_and_inhibited_profile_do_not_write(self):
        self.client.send('select', profile='invented')
        self.client.wait(lambda m: m.get('type') == 'error')
        self.bus.props[(self.bus.path, self.bus.name)]['PerformanceInhibited'] = GLib.Variant('s', 'lap-detected')
        self.bus.changed()
        self.state('balanced', inhibited='lap-detected')
        self.client.send('select', profile='performance')
        self.client.wait(lambda m: m.get('type') == 'error')
        self.assertEqual(self.bus.props[(self.bus.path, self.bus.name)]['ActiveProfile'].unpack(), 'balanced')

    def test_game_hold_restores_previous_profile(self):
        self.client.send('game', enabled=True)
        self.state('performance', gameHold=True)
        self.client.send('game', enabled=False)
        self.state('balanced', gameHold=False)
        self.assertEqual(self.bus.calls, ['HoldProfile', 'ReleaseProfile'])

    def test_manual_selection_overrides_game_hold(self):
        self.client.send('game', enabled=True)
        self.state('performance', gameHold=True)
        self.client.send('select', profile='power-saver')
        self.state('power-saver', gameHold=False)
        self.client.send('game', enabled=False)
        self.state('power-saver', gameHold=False)

    def test_external_hold_release_respects_manual_choice(self):
        self.client.send('game', enabled=True)
        self.state('performance', gameHold=True)
        self.bus.cookie = None
        self.bus.connection.emit_signal(None, self.bus.path, self.bus.name, 'ProfileReleased', GLib.Variant('(u)', (42,)))
        self.bus.set_active('power-saver')
        self.state('power-saver', gameHold=False)
        self.client.send('game', enabled=True)
        self.state('power-saver', gameHold=False)
        self.assertEqual(self.bus.calls, ['HoldProfile'])

    def test_legacy_service(self):
        self.client.close()
        self.bus.close()
        self.bus = PowerBus(legacy=True)
        self.client = Client('power_control.py', self.bus.address)
        self.state('balanced')
        self.client.send('select', profile='performance')
        self.state('performance')


if __name__ == '__main__':
    unittest.main()

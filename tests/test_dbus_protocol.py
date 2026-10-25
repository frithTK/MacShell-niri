"""Real Gio messages on a private bus; never connect to desktop/system services."""
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import sys
import threading
import time
import unittest

sys.path.insert(0, str(Path(__file__).parents[1] / 'MacShell'))
from gi.repository import Gio, GLib
import bluetooth_service as bt
import network_control as net


class PrivateBus:
    def __init__(self):
        self.daemon = subprocess.Popen(['dbus-daemon', '--session', '--nofork', '--print-address=1'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        self.address = self.daemon.stdout.readline().strip()
        self.connection = Gio.DBusConnection.new_for_address_sync(self.address, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
        self.ids = []
        self.props = {}
        self.reads = {}
        self.agents = {}
        self.discovery = 1  # Another client already owns one discovery reference.
        self.active = 1
        self.settings = None
        self.secret = None
        for name in ('org.bluez', net.NM):
            self.connection.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'RequestName', GLib.Variant('(su)', (name, 0)), None, Gio.DBusCallFlags.NONE, 1000, None)
        self.register('/', 'org.freedesktop.DBus.ObjectManager', '<method name="GetManagedObjects"><arg type="a{oa{sa{sv}}}" direction="out"/></method>')
        self.register('/org/bluez', 'org.bluez.AgentManager1', '<method name="RegisterAgent"><arg type="o" direction="in"/><arg type="s" direction="in"/></method>')
        self.register('/org/bluez/hci0', bt.ADAPTER, '<method name="StartDiscovery"/><method name="StopDiscovery"/>', {'Powered': ('b', True), 'Alias': ('s', 'Adapter')})
        self.device = '/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF'
        self.register(self.device, bt.DEVICE, '<method name="Pair"/><method name="CancelPairing"/><method name="Connect"/><method name="Disconnect"/>', {'Adapter': ('o', '/org/bluez/hci0'), 'Alias': ('s', 'Test Keyboard'), 'Address': ('s', 'AA:BB:CC:DD:EE:FF'), 'Paired': ('b', False), 'Connected': ('b', False), 'Trusted': ('b', False), 'Blocked': ('b', False)})
        root_methods = '<method name="AddAndActivateConnection2"><arg type="a{sa{sv}}" direction="in"/><arg type="o" direction="in"/><arg type="o" direction="in"/><arg type="a{sv}" direction="in"/><arg type="o" direction="out"/><arg type="o" direction="out"/><arg type="a{sv}" direction="out"/></method><method name="DeactivateConnection"><arg type="o" direction="in"/></method>'
        self.register(net.ROOT, net.NM, root_methods, {'Devices': ('ao', [net.ROOT + '/Devices/1']), 'WirelessEnabled': ('b', True), 'WirelessHardwareEnabled': ('b', True), 'Connectivity': ('u', 4)})
        self.register(net.ROOT + '/AgentManager', net.NM + '.AgentManager', '<method name="Register"><arg type="s" direction="in"/></method>')
        self.register(net.ROOT + '/Settings', net.NM + '.Settings', '<method name="ListConnections"><arg type="ao" direction="out"/></method>')
        self.register(net.ROOT + '/Devices/1', net.DEV, '<method name="Disconnect"/>', {'DeviceType': ('u', 2), 'Interface': ('s', 'wlan0'), 'State': ('u', 30), 'ActiveConnection': ('o', '/')})
        self.ap = net.ROOT + '/AccessPoint/1'
        self.register(net.ROOT + '/Devices/1', net.WIFI, '<method name="RequestScan"><arg type="a{sv}" direction="in"/></method>', {'AccessPoints': ('ao', [self.ap]), 'ActiveAccessPoint': ('o', '/')})
        self.register(self.ap, net.AP, '', {'Ssid': ('ay', list(b'Test WiFi')), 'Strength': ('y', 80), 'Flags': ('u', 1), 'WpaFlags': ('u', 0), 'RsnFlags': ('u', 0x100)})
        self.profile = net.ROOT + '/Settings/1'
        self.register(self.profile, net.CON, '<method name="GetSettings"><arg type="a{sa{sv}}" direction="out"/></method>')
        self.active_path = net.ROOT + '/ActiveConnection/1'
        self.register(self.active_path, net.ACTIVE, '', {'State': ('u', 1), 'Connection': ('o', self.profile)})
        self.loop = GLib.MainLoop()
        self.thread = threading.Thread(target=self.loop.run, daemon=True)
        self.thread.start()

    def register(self, path, interface, methods, properties=None):
        properties = properties or {}
        self.props[(path, interface)] = {k: GLib.Variant(sig, value) for k, (sig, value) in properties.items()}
        xml = '<node><interface name="' + interface + '">' + methods + ''.join('<property name="' + key + '" type="' + sig + '" access="readwrite"/>' for key, (sig, value) in properties.items()) + '</interface></node>'
        def get_prop(bus, sender, path, iface, name):
            key = (path, iface, name)
            self.reads[key] = self.reads.get(key, 0) + 1
            return self.props[(path, iface)][name]
        def set_prop(bus, sender, path, iface, name, value):
            self.props[(path, iface)][name] = value
            return True
        self.ids.append(self.connection.register_object(path, Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0], self.method, get_prop, set_prop))

    def method(self, bus, sender, path, iface, method, parameters, invocation):
        if method == 'GetManagedObjects':
            objects = {}
            for (p, interface), props in self.props.items():
                if interface in (bt.ADAPTER, bt.DEVICE):
                    objects.setdefault(p, {})[interface] = props
            invocation.return_value(GLib.Variant('(a{oa{sa{sv}}})', (objects,)))
        elif method == 'RegisterAgent':
            self.agents['bt'] = (sender, parameters.unpack()[0]); invocation.return_value(None)
        elif method == 'Register':
            self.agents['wifi'] = (sender, net.AGENT_PATH); invocation.return_value(None)
        elif method == 'StartDiscovery':
            self.discovery += 1; invocation.return_value(None)
        elif method == 'StopDiscovery':
            self.discovery -= 1; invocation.return_value(None)
        elif method == 'Pair':
            peer, agent_path = self.agents['bt']
            def confirmed(bus, result):
                try:
                    bus.call_finish(result)
                    self.props[(self.device, bt.DEVICE)]['Paired'] = GLib.Variant('b', True)
                    invocation.return_value(None)
                except GLib.Error:
                    invocation.return_dbus_error('org.bluez.Error.AuthenticationCanceled', 'Canceled')
            bus.call(peer, agent_path, bt.AGENT, 'RequestConfirmation', GLib.Variant('(ou)', (self.device, 42)), None, Gio.DBusCallFlags.NONE, 6000, None, confirmed)
        elif method in ('Connect', 'Disconnect') and iface == bt.DEVICE:
            self.props[(self.device, bt.DEVICE)]['Connected'] = GLib.Variant('b', method == 'Connect')
            invocation.return_value(None)
        elif method == 'ListConnections':
            invocation.return_value(GLib.Variant('(ao)', ([self.profile] if self.settings else [],)))
        elif method == 'GetSettings':
            invocation.return_value(GLib.Variant.new_tuple(self.settings))
        elif method == 'AddAndActivateConnection2':
            self.settings = parameters.get_child_value(0)
            peer, agent_path = self.agents['wifi']
            def secrets(bus, result):
                try:
                    self.secret = bus.call_finish(result).unpack()[0]['802-11-wireless-security']['psk']
                    invocation.return_value(GLib.Variant('(ooa{sv})', (self.profile, self.active_path, {})))
                    self.connection.emit_signal(None, net.ROOT + '/Settings', net.NM + '.Settings', 'NewConnection', GLib.Variant('(o)', (self.profile,)))
                except GLib.Error:
                    invocation.return_dbus_error(net.NM + '.Error.Failed', 'No secrets')
            params = GLib.Variant.new_tuple(self.settings, GLib.Variant('o', self.profile), GLib.Variant('s', '802-11-wireless-security'), GLib.Variant('as', []), GLib.Variant('u', 1))
            bus.call(peer, agent_path, net.AGENT, 'GetSecrets', params, None, Gio.DBusCallFlags.NONE, 6000, None, secrets)
        else:
            invocation.return_value(None)

    def close(self):
        self.loop.quit(); self.thread.join(timeout=3)
        for registration in self.ids: self.connection.unregister_object(registration)
        self.connection.close_sync(None)
        self.daemon.terminate(); self.daemon.wait(timeout=3); self.daemon.stdout.close()


class Client:
    def __init__(self, script, address=None, environment=None):
        env = dict(os.environ, **(environment or {}))
        if address is not None: env["DBUS_SYSTEM_BUS_ADDRESS"] = address
        self.process = subprocess.Popen([sys.executable, '-u', str(Path(__file__).parents[1] / 'MacShell' / script)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, text=True)
        self.queue = queue.Queue()
        self.lines = []
        def read():
            for line in self.process.stdout:
                self.queue.put(json.loads(line))
        self.thread = threading.Thread(target=read, daemon=True); self.thread.start()
        self.sequence = 0

    def send(self, action, **data):
        self.sequence += 1
        self.process.stdin.write(json.dumps({'id': self.sequence, 'generation': 7, 'action': action, 'data': data}) + '\n'); self.process.stdin.flush()
        return self.sequence

    def wait(self, predicate, timeout=7):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try: message = self.queue.get(timeout=.1)
            except queue.Empty: continue
            self.lines.append(message)
            if predicate(message): return message
        raise AssertionError('No expected service reply: ' + repr(self.lines[-6:]))

    def close(self):
        self.process.stdin.close()
        try: self.process.wait(timeout=5)
        except subprocess.TimeoutExpired: self.process.kill(); self.process.wait()
        self.thread.join(timeout=2)
        errors = self.process.stderr.read()
        self.process.stdout.close(); self.process.stderr.close()
        if errors: raise AssertionError(errors)


@unittest.skipUnless(shutil.which('dbus-daemon'), 'dbus-daemon is required')
class DbusProtocolTests(unittest.TestCase):
    def test_nm_updates_on_signals_without_periodic_full_queries(self):
        server = PrivateBus()
        client = Client('network_control.py', server.address)
        try:
            client.wait(lambda m: m.get('type') == 'state' and m.get('networks'))
            key = (net.ROOT, net.NM, 'Devices')
            reads = server.reads[key]
            time.sleep(2.6)
            self.assertEqual(server.reads[key], reads)
            server.props[(server.ap, net.AP)]['Strength'] = GLib.Variant('y', 42)
            server.connection.emit_signal(None, server.ap, net.PROPS, 'PropertiesChanged',
                GLib.Variant('(sa{sv}as)', (net.AP, {'Strength': GLib.Variant('y', 42)}, [])))
            state = client.wait(lambda m: m.get('type') == 'state' and m['networks'][0]['signal'] == 42)
            self.assertEqual(state['networks'][0]['ssid'], 'Test WiFi')
            reads = server.reads[key]
            client.send('refresh')
            client.wait(lambda m: m.get('type') == 'state' and m['networks'][0]['signal'] == 42)
            self.assertGreater(server.reads[key], reads)
        finally:
            try: client.close()
            finally: server.close()

    def test_real_bluez_agent_pair_trust_connect_and_discovery_ownership(self):
        server = PrivateBus()
        client = Client('bluetooth_service.py', server.address)
        try:
            client.wait(lambda m: m.get('type') == 'state' and m.get('pairingAvailable'))
            client.send('discover')
            client.wait(lambda m: m.get('discovering') is True)
            rid = client.send('pair', path=server.device)
            prompt = client.wait(lambda m: m.get('type') == 'prompt' and m.get('prompt'))['prompt']
            self.assertEqual(prompt['code'], '000042')
            self.assertFalse(server.props[(server.device, bt.DEVICE)]['Paired'].unpack())
            client.send('respond', prompt=prompt['id'], accept=True)
            result = client.wait(lambda m: m.get('type') == 'result' and m.get('id') == rid)
            self.assertTrue(result['ok'])
            self.assertTrue(server.props[(server.device, bt.DEVICE)]['Trusted'].unpack())
            self.assertTrue(server.props[(server.device, bt.DEVICE)]['Connected'].unpack())
            client.send('stopDiscovery')
            client.wait(lambda m: m.get('type') == 'state' and m.get('discovering') is False)
            self.assertEqual(server.discovery, 1)
        finally:
            try: client.close()
            finally: server.close()

    def test_real_nm_secret_exchange_and_activation_completion(self):
        server = PrivateBus()
        client = Client('network_control.py', server.address)
        try:
            state = client.wait(lambda m: m.get('type') == 'state' and m.get('networks'))
            self.assertEqual(state['networks'][0]['ssid'], 'Test WiFi')
            rid = client.send('join', network=server.ap, password='test password')
            client.wait(lambda m: m.get('type') == 'state')
            self.assertEqual(server.secret, 'test password')
            self.assertFalse(any(m.get('type') == 'result' and m.get('id') == rid for m in client.lines))
            server.props[(server.active_path, net.ACTIVE)]['State'] = GLib.Variant('u', 2)
            result = client.wait(lambda m: m.get('type') == 'result' and m.get('id') == rid)
            self.assertEqual(result['state'], 'connected')
            self.assertTrue(result['ok'])
        finally:
            try: client.close()
            finally: server.close()

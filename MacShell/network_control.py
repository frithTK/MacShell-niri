#!/usr/bin/env python3
"""NetworkManager Wi-Fi client: raw SSID identity, scoped secrets and activation."""
import os
import pwd
import time
import uuid
from dbus_service import Service, Gio, GLib, PROPS, run

NM = 'org.freedesktop.NetworkManager'
ROOT = '/org/freedesktop/NetworkManager'
WIFI = NM + '.Device.Wireless'
DEV = NM + '.Device'
AP = NM + '.AccessPoint'
CON = NM + '.Settings.Connection'
ACTIVE = NM + '.Connection.Active'
AGENT = NM + '.SecretAgent'
AGENT_PATH = ROOT + '/SecretAgent'
AGENT_XML = '''<node><interface name="org.freedesktop.NetworkManager.SecretAgent">
<method name="GetSecrets"><arg type="a{sa{sv}}" direction="in"/><arg type="o" direction="in"/><arg type="s" direction="in"/><arg type="as" direction="in"/><arg type="u" direction="in"/><arg type="a{sa{sv}}" direction="out"/></method>
<method name="CancelGetSecrets"><arg type="o" direction="in"/><arg type="s" direction="in"/></method>
<method name="SaveSecrets"><arg type="a{sa{sv}}" direction="in"/><arg type="o" direction="in"/></method>
<method name="DeleteSecrets"><arg type="a{sa{sv}}" direction="in"/><arg type="o" direction="in"/></method>
</interface></node>'''


def security(props):
    flags = props.get('WpaFlags', 0) | props.get('RsnFlags', 0)
    if flags & (0x200 | 0x2000):
        return 'enterprise'
    if flags & (0x800 | 0x1000):
        return 'owe'
    if flags & 0x400:
        return 'sae'
    if flags & 0x100:
        return 'wpa-psk'
    return 'unsupported' if props.get('Flags', 0) & 1 else 'open'


def compatible(settings, ssid, kind, interface):
    wireless = settings.get('802-11-wireless', {})
    connection = settings.get('connection', {})
    key = settings.get('802-11-wireless-security', {}).get('key-mgmt', 'open')
    return (bytes(wireless.get('ssid', [])) == bytes(ssid) and key == kind
            and connection.get('interface-name', interface) == interface)


def choose_profile(profiles, ssid, kind, interface, active):
    matching = [(path, settings) for path, settings in profiles.items() if compatible(settings, ssid, kind, interface)]
    matching.sort(key=lambda row: (row[0] != active, -row[1].get('connection', {}).get('timestamp', 0), row[1].get('connection', {}).get('uuid', '')))
    return matching[0][0] if matching else ''


def make_profile(net, password):
    kind = net['security']
    if kind not in ('open', 'wpa-psk', 'sae'):
        raise ValueError('This security type needs advanced network settings.')
    if kind == 'wpa-psk' and not (8 <= len(password) <= 63 or len(password) == 64 and all(c in '0123456789abcdefABCDEF' for c in password)):
        raise ValueError('WPA password must contain 8–63 characters (or 64 hexadecimal digits).')
    if kind == 'sae' and not (1 <= len(password) <= 63):
        raise ValueError('Enter the WPA3 password (1–63 characters).')
    settings = {'connection': {'id': GLib.Variant('s', net['ssid']), 'uuid': GLib.Variant('s', str(uuid.uuid4())),
                              'type': GLib.Variant('s', '802-11-wireless'),
                              'interface-name': GLib.Variant('s', net['interface']),
                              'permissions': GLib.Variant('as', ['user:' + pwd.getpwuid(os.getuid()).pw_name + ':'])},
                '802-11-wireless': {'ssid': GLib.Variant('ay', net['rawSsid']), 'mode': GLib.Variant('s', 'infrastructure')},
                'ipv4': {'method': GLib.Variant('s', 'auto')}, 'ipv6': {'method': GLib.Variant('s', 'auto')}}
    if kind != 'open':
        settings['802-11-wireless-security'] = {'key-mgmt': GLib.Variant('s', kind), 'psk': GLib.Variant('s', password), 'psk-flags': GLib.Variant('u', 0)}
    return settings


class NetworkService(Service):
    destination = NM

    def __init__(self):
        self.pending = None
        self.networks = {}
        self.profiles = {}
        self.secret_request = None
        self.agent_id = None
        self.agent_ready = False
        self.profiles_dirty = True
        self.snapshot_due = time.monotonic() + 30
        self.snapshot_timer = 0
        self.last_state = None
        super().__init__()
        info = Gio.DBusNodeInfo.new_for_xml(AGENT_XML).interfaces[0]
        self.agent_id = self.bus.register_object(AGENT_PATH, info, self.agent, None, None)
        # Devices, APs and saved profiles each have their own object paths.
        self.subscription = self.bus.signal_subscribe(NM, None, None, None, None, Gio.DBusSignalFlags.NONE, self.changed)
        self.tick_timer = GLib.timeout_add_seconds(2, self.tick)

    def changed(self, connection, sender, path, interface, signal, parameters):
        if sender != self.owner or not (path == ROOT or path.startswith(ROOT + '/')):
            return
        if interface == PROPS:
            changed_interface, values, invalidated = parameters.unpack()
            if not changed_interface.startswith(NM):
                return
            watched = {NM: {'Devices', 'WirelessEnabled', 'WirelessHardwareEnabled', 'Connectivity'},
                       NM + '.Settings': {'Connections'},
                       DEV: {'DeviceType', 'State', 'ActiveConnection', 'Interface'},
                       WIFI: {'AccessPoints', 'ActiveAccessPoint', 'LastScan'},
                       AP: {'Ssid', 'Strength', 'Flags', 'WpaFlags', 'RsnFlags'},
                       ACTIVE: {'State', 'Connection'}}
            if changed_interface != CON and not (set(values) | set(invalidated)) & watched.get(changed_interface, set()):
                return
        elif not interface.startswith(NM):
            return
        if path.startswith(ROOT + '/Settings'):
            self.profiles_dirty = True
        if not self.snapshot_timer:
            self.snapshot_timer = GLib.timeout_add(100, self.flush_snapshot)

    def flush_snapshot(self):
        self.snapshot_timer = 0
        self.snapshot()
        return False

    def appeared(self, connection, name, owner):
        self.profiles_dirty, self.last_state = True, None
        self.snapshot_due = time.monotonic() + 30
        super().appeared(connection, name, owner)
        def registered(value, error):
            self.agent_ready = error is None
            if error:
                self.emit(type='error', error='Cannot register the Wi-Fi password agent. Check permissions and retry.')
            self.snapshot()
        self.async_call(ROOT + '/AgentManager', NM + '.AgentManager', 'Register',
                        GLib.Variant('(s)', ('org.macshell.niri',)), registered)

    def vanished(self, connection, name):
        self.agent_ready = False
        self.finish('NetworkManager restarted or disappeared.')
        self.networks = {}
        self.profiles, self.last_state, self.profiles_dirty = {}, None, True
        super().vanished(connection, name)

    def snapshot(self, force=False):
        if not self.owner:
            return
        try:
            root = self.props(ROOT, NM)
            if self.profiles_dirty:
                profiles = {}
                for path in self.sync(ROOT + '/Settings', NM + '.Settings', 'ListConnections')[0]:
                    try:
                        profiles[path] = self.sync(path, CON, 'GetSettings')[0]
                    except GLib.Error:
                        continue
                self.profiles, self.profiles_dirty = profiles, False
            profiles = self.profiles
            networks, ethernet = {}, False
            for device in root.get('Devices', []):
                props = self.props(device, DEV)
                if props.get('DeviceType') == 1 and props.get('State') == 100:
                    ethernet = True
                if props.get('DeviceType') != 2:
                    continue
                wifi = self.props(device, WIFI)
                active = props.get('ActiveConnection', '/')
                active_profile = self.props(active, ACTIVE).get('Connection', '') if active != '/' else ''
                for path in wifi.get('AccessPoints', []):
                    try:
                        ap = self.props(path, AP)
                    except GLib.Error:
                        continue
                    raw = list(ap.get('Ssid', []))
                    if not raw:
                        continue
                    kind = security(ap)
                    profile = choose_profile(profiles, raw, kind, props.get('Interface', ''), active_profile)
                    networks[path] = {'id': path, 'ap': path, 'device': device, 'interface': props.get('Interface', ''),
                                      'ssid': bytes(raw).decode('utf-8', 'replace'), 'rawSsid': raw,
                                      'signal': ap.get('Strength', 0), 'security': kind, 'secure': kind != 'open',
                                      'supported': kind in ('open', 'wpa-psk', 'sae'), 'inUse': path == wifi.get('ActiveAccessPoint'),
                                      'saved': bool(profile), 'profile': profile,
                                      'uuid': profiles.get(profile, {}).get('connection', {}).get('uuid', '')}
            self.networks = networks
            state = dict(type='state', available=True, enabled=root.get('WirelessEnabled', False),
                      hardwareEnabled=root.get('WirelessHardwareEnabled', False), ethernet=ethernet,
                      connectivity=root.get('Connectivity', 0), networks=sorted(networks.values(), key=lambda n: (not n['inUse'], -n['signal'], n['id'])))
            if force or state != self.last_state:
                self.last_state = state
                self.emit(**state)
        except GLib.Error:
            self.emit(type='error', error='Cannot read Wi-Fi status. Check NetworkManager permissions.')

    def agent(self, bus, sender, path, interface, method, params, invocation):
        args = params.unpack()
        if sender != self.owner:
            invocation.return_dbus_error(AGENT + '.NotAuthorized', 'Unknown caller')
            return
        if method in ('SaveSecrets', 'DeleteSecrets', 'CancelGetSecrets'):
            if method == 'CancelGetSecrets' and self.secret_request:
                self.secret_request.return_dbus_error(AGENT + '.AgentCanceled', 'Canceled')
                self.secret_request = None
            invocation.return_value(None)
            return
        if method == 'GetSecrets':
            settings, profile, name, hints, flags = args
            current = self.pending
            identity = settings.get('connection', {}).get('uuid')
            if not current or identity != current.get('uuid') or name != '802-11-wireless-security':
                invocation.return_dbus_error(AGENT + '.NoSecrets', 'No secrets for this connection')
                return
            if current.get('password') and not current.get('passwordUsed'):
                current['passwordUsed'] = True
                invocation.return_value(GLib.Variant('(a{sa{sv}})', ({name: {'psk': GLib.Variant('s', current['password'])}},)))
            elif self.secret_request is None:
                self.secret_request = invocation
                self.emit(type='secret', id=current['id'], network=current['network'], error='Enter the password for this network.')
            else:
                invocation.return_dbus_error(AGENT + '.NoSecrets', 'A password request is already open')

    def finish(self, error='', state='failed'):
        current, self.pending = self.pending, None
        if self.secret_request:
            self.secret_request.return_dbus_error(AGENT + '.AgentCanceled', 'Canceled')
            self.secret_request = None
        if current:
            self.emit(type='result', id=current['id'], ok=not error, state=state, error=error)

    def tick(self):
        p = self.pending
        if p and p.get('active'):
            try:
                state = self.props(p['active'], ACTIVE).get('State', 0)
                if state == 2:
                    self.finish(state='connected')
                elif state == 4:
                    self.finish('Connection failed. Check the password and signal.')
                elif time.monotonic() > p['deadline']:
                    self.cancel(p['id'], timed_out=True)
            except GLib.Error:
                self.finish('The connection disappeared before it was activated.')
        if time.monotonic() >= self.snapshot_due:
            self.snapshot_due = time.monotonic() + 30
            self.profiles_dirty = True  # Recover from a missed profile signal.
            self.snapshot()
        return True

    def cancel(self, request_id, timed_out=False):
        p = self.pending
        if not p or p['id'] != request_id:
            return
        p['cancel'] = True
        if self.secret_request:
            self.secret_request.return_dbus_error(AGENT + '.UserCanceled', 'Canceled by user')
            self.secret_request = None
        if not p.get('active'):
            return  # Method may still return an operation-owned ActiveConnection.
        try:
            # Never disconnect an already-activated connection or a different client.
            state = self.props(p['active'], ACTIVE).get('State')
            if state == 2:
                self.finish(state='connected')
                return
            if state == 1:
                self.async_call(ROOT, NM, 'DeactivateConnection', GLib.Variant('(o)', (p['active'],)), lambda v, e: None)
        except GLib.Error:
            pass
        self.finish('Connection timed out.' if timed_out else '', 'canceled')

    def command(self, request):
        action, data, rid = request['action'], request.get('data', {}), request['id']
        if action == 'refresh':
            self.profiles_dirty = True
            self.snapshot(force=True)
        elif action == 'scan':
            for device in self.props(ROOT, NM).get('Devices', []):
                if self.props(device, DEV).get('DeviceType') == 2:
                    self.async_call(device, WIFI, 'RequestScan', GLib.Variant('(a{sv})', ({},)), lambda v, e: self.snapshot())
        elif action == 'power':
            self.async_call(ROOT, PROPS, 'Set', GLib.Variant('(ssv)', (NM, 'WirelessEnabled', GLib.Variant('b', bool(data['enabled'])))), lambda v, e: self.emit(type='error', error='Wi-Fi radio change failed.') if e else self.snapshot())
        elif action == 'cancel':
            self.cancel(data['request'])
        elif action == 'secret':
            if self.pending and self.pending['id'] == data['request'] and self.secret_request:
                invocation, self.secret_request = self.secret_request, None
                password = str(data['password'])
                invocation.return_value(GLib.Variant('(a{sa{sv}})', ({'802-11-wireless-security': {'psk': GLib.Variant('s', password)}},)))
        elif action == 'disconnect':
            net = self.networks.get(data.get('network'))
            if net:
                self.async_call(net['device'], DEV, 'Disconnect', None, lambda v, e: self.snapshot())
        elif action == 'join':
            if self.pending:
                raise ValueError('Wait for the current Wi-Fi request or cancel it.')
            net = self.networks.get(data.get('network'))
            if not net:
                raise ValueError('This access point is no longer available. Scan again.')
            if net.get('secure', True) and not self.agent_ready:
                raise ValueError('The Wi-Fi password agent is not ready. Try again in a moment.')
            if not net['supported']:
                raise ValueError('This network needs advanced network settings.')
            password = str(data.get('password', ''))
            p = {'id': rid, 'network': net, 'uuid': net['uuid'], 'password': password, 'active': None, 'deadline': time.monotonic() + 45, 'cancel': False}
            self.pending = p
            def activated(value, error):
                if self.pending is not p:
                    return
                if error:
                    self.finish('', 'canceled') if p['cancel'] else self.finish('Could not activate this network. Check the password, radio and permissions.')
                    return
                p['active'] = value[0] if net['saved'] else value[1]
                if p['cancel']:
                    self.cancel(p['id'])
            try:
                if net['saved']:
                    self.async_call(ROOT, NM, 'ActivateConnection', GLib.Variant('(ooo)', (net['profile'], net['device'], net['ap'])), activated)
                else:
                    settings = make_profile(net, password)
                    p['uuid'] = settings['connection']['uuid'].unpack()
                    self.async_call(ROOT, NM, 'AddAndActivateConnection2', GLib.Variant('(a{sa{sv}}ooa{sv})', (settings, net['device'], net['ap'], {'persist': GLib.Variant('s', 'disk')})), activated)
            except (ValueError, GLib.Error):
                self.pending = None
                raise
        else:
            raise ValueError('Unknown Wi-Fi action.')

    def close(self):
        if self.closed:
            return
        for timer in (self.snapshot_timer, self.tick_timer):
            if timer:
                GLib.source_remove(timer)
        self.bus.signal_unsubscribe(self.subscription)
        if self.agent_id:
            self.bus.unregister_object(self.agent_id)
        super().close()


if __name__ == '__main__':
    run(NetworkService)

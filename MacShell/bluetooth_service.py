#!/usr/bin/env python3
"""One BlueZ connection for discovery, pairing and its non-default UI agent."""
import re
import time
from bluetooth_control import ADAPTER, DEVICE, BATTERY, snapshot, error_message
from dbus_service import Service, Gio, GLib, PROPS, run

AGENT = 'org.bluez.Agent1'
PATH = '/org/macshell/BluetoothAgent'
XML = '''<node><interface name="org.bluez.Agent1">
<method name="Release"/>
<method name="RequestPinCode"><arg type="o" direction="in"/><arg type="s" direction="out"/></method>
<method name="DisplayPinCode"><arg type="o" direction="in"/><arg type="s" direction="in"/></method>
<method name="RequestPasskey"><arg type="o" direction="in"/><arg type="u" direction="out"/></method>
<method name="DisplayPasskey"><arg type="o" direction="in"/><arg type="u" direction="in"/><arg type="q" direction="in"/></method>
<method name="RequestConfirmation"><arg type="o" direction="in"/><arg type="u" direction="in"/></method>
<method name="RequestAuthorization"><arg type="o" direction="in"/></method>
<method name="AuthorizeService"><arg type="o" direction="in"/><arg type="s" direction="in"/></method>
<method name="Cancel"/>
</interface></node>'''


def discovered(objects):
    known = snapshot(objects)
    unpaired = {}
    for path, interfaces in objects.items():
        d = interfaces.get(DEVICE)
        if d and not (d.get('Paired') or d.get('Bonded') or d.get('Connected')):
            unpaired[path] = dict(interfaces, **{DEVICE: dict(d, Paired=True)})
        elif ADAPTER in interfaces:
            unpaired[path] = interfaces
    known['others'] = snapshot(unpaired)['devices']
    for device in known['devices']:
        device['paired'] = bool(objects[device['path']][DEVICE].get('Paired') or objects[device['path']][DEVICE].get('Bonded'))
    return known


class BluetoothService(Service):
    destination = 'org.bluez'

    def __init__(self):
        self.pending = None
        self.prompt = None
        self.prompt_sequence = 0
        self.discovery = set()
        self.discovery_until = 0
        self.registered = False
        super().__init__()
        self.agent_id = self.bus.register_object(PATH, Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0], self.agent, None, None)
        GLib.timeout_add_seconds(2, self.tick)

    def friendly_error(self, error):
        return error_message(error)

    def appeared(self, connection, name, owner):
        super().appeared(connection, name, owner)
        def registered(value, error):
            self.registered = error is None
            if error:
                self.emit(type='error', error='Bluetooth pairing agent could not register.')
            self.snapshot()
        self.async_call('/org/bluez', 'org.bluez.AgentManager1', 'RegisterAgent', GLib.Variant('(os)', (PATH, 'KeyboardDisplay')), registered)

    def vanished(self, connection, name):
        self.registered = False
        self.discovery.clear()
        self.clear_prompt()
        self.finish('Bluetooth restarted or disappeared.')
        super().vanished(connection, name)

    def objects(self):
        return self.sync('/', 'org.freedesktop.DBus.ObjectManager', 'GetManagedObjects')[0]

    def snapshot(self):
        if not self.owner:
            return
        try:
            self.emit(type='state', discovering=bool(self.discovery), pairingAvailable=self.registered, **discovered(self.objects()))
        except GLib.Error as error:
            self.emit(type='error', error=error_message(error))

    def clear_prompt(self):
        if self.prompt and self.prompt.get('invocation'):
            self.prompt['invocation'].return_dbus_error('org.bluez.Error.Canceled', 'Canceled by user')
        self.prompt = None
        self.emit(type='prompt', prompt=None)

    def finish(self, error='', phase='connected'):
        pending, self.pending = self.pending, None
        self.clear_prompt()
        if pending:
            self.emit(type='result', id=pending['id'], ok=not error, phase=phase, error=error)
        self.snapshot()

    def agent(self, bus, sender, path, interface, method, parameters, invocation):
        args = parameters.unpack()
        if sender != self.owner:
            invocation.return_dbus_error('org.bluez.Error.Rejected', 'Unknown caller')
            return
        if method in ('Cancel', 'Release'):
            self.clear_prompt()
            if method == 'Release':
                self.registered = False
            invocation.return_value(None)
            return
        p = self.pending
        if not p or p['action'] != 'pair' or not args or args[0] != p['path']:
            invocation.return_dbus_error('org.bluez.Error.Rejected', 'No user-initiated pairing for this device')
            return
        self.clear_prompt()
        self.prompt_sequence += 1
        display = method in ('DisplayPinCode', 'DisplayPasskey')
        prompt = {'id': self.prompt_sequence, 'request': p['id'], 'method': method, 'device': p['path'],
                  'name': p.get('name', 'Bluetooth device'), 'code': str(args[1]) if method == 'DisplayPinCode' else f'{args[1]:06d}' if method in ('DisplayPasskey', 'RequestConfirmation') else '',
                  'entered': args[2] if method == 'DisplayPasskey' else 0,
                  'service': args[1] if method == 'AuthorizeService' else ''}
        self.prompt = dict(prompt, invocation=None if display else invocation)
        self.emit(type='prompt', prompt=prompt)
        if display:
            invocation.return_value(None)

    def respond(self, data):
        p = self.prompt
        if not p or p['id'] != data.get('prompt') or not self.pending or p['request'] != self.pending['id']:
            return
        if not data.get('accept'):
            self.cancel()
            return
        invocation = p.get('invocation')
        if invocation is None:
            return
        method = p['method']
        value = str(data.get('value', ''))
        if method == 'RequestPinCode':
            if not 1 <= len(value.encode('utf-8')) <= 16:
                raise ValueError('PIN must contain 1–16 bytes.')
            reply = GLib.Variant('(s)', (value,))
        elif method == 'RequestPasskey':
            if not re.fullmatch(r'[0-9]{1,6}', value):
                raise ValueError('Passkey must contain up to six digits.')
            reply = GLib.Variant('(u)', (int(value),))
        else:
            reply = None
        invocation.return_value(reply)
        p['invocation'] = None
        self.clear_prompt()

    def cancel(self):
        p = self.pending
        if p and p['action'] == 'pair':
            self.async_call(p['path'], DEVICE, 'CancelPairing', None, lambda v, e: None, 3000)
        self.finish('', 'canceled')

    def stop_discovery(self):
        for path in list(self.discovery):
            self.async_call(path, ADAPTER, 'StopDiscovery', None, lambda v, e: None, 3000)
        self.discovery.clear()
        self.discovery_until = 0

    def tick(self):
        if self.discovery_until and time.monotonic() > self.discovery_until:
            self.stop_discovery()
        if self.pending and time.monotonic() > self.pending['deadline']:
            self.cancel()
            self.emit(type='error', error='Bluetooth request timed out. Check the device and try again.')
        self.snapshot()
        return True

    def command(self, request):
        action, data, rid = request['action'], request.get('data', {}), request['id']
        if action == 'refresh':
            self.snapshot()
            return
        if action == 'respond':
            self.respond(data)
            return
        if action == 'cancel':
            if self.pending and data.get('request') == self.pending['id']:
                self.cancel()
            return
        if action == 'stopDiscovery':
            self.stop_discovery()
            self.snapshot()
            return
        if self.pending:
            raise ValueError('Wait for the current Bluetooth operation or cancel it.')
        if action == 'discover':
            self.discovery_until = time.monotonic() + 30
            for adapter in discovered(self.objects())['adapters']:
                path = adapter['path']
                if adapter['enabled'] and path not in self.discovery:
                    def started(value, error, path=path):
                        if not error:
                            self.discovery.add(path)
                            if not self.discovery_until:
                                self.stop_discovery()
                        else:
                            self.emit(type='error', error=error_message(error))
                        self.snapshot()
                    self.async_call(path, ADAPTER, 'StartDiscovery', None, started)
            return
        if action == 'power':
            adapters = discovered(self.objects())['adapters']
            self.stop_discovery()
            p = {'id': rid, 'action': action, 'path': '', 'deadline': time.monotonic() + 10}
            self.pending = p
            targets = [a for a in adapters if a['enabled'] != bool(data['enabled'])]
            if not targets:
                self.finish()
            for a in targets:
                def powered(value, error, a=a):
                    if self.pending is not p:
                        return
                    if error:
                        self.finish(error_message(error))
                    else:
                        targets.remove(a)
                        if not targets:
                            self.finish()
                self.async_call(a['path'], PROPS, 'Set', GLib.Variant('(ssv)', (ADAPTER, 'Powered', GLib.Variant('b', bool(data['enabled'])))), powered)
            return
        path = data.get('path', '')
        if not re.fullmatch(r'/org/bluez/hci\d+/dev_(?:[0-9A-Fa-f]{2}_){5}[0-9A-Fa-f]{2}', path):
            raise ValueError('Invalid Bluetooth device.')
        if action not in ('pair', 'connect', 'disconnect'):
            raise ValueError('Unknown Bluetooth action.')
        if action == 'pair' and not self.registered:
            raise ValueError('The pairing agent is unavailable. Reopen Bluetooth and try again.')
        props = self.props(path, DEVICE)
        p = {'id': rid, 'action': action, 'path': path, 'name': props.get('Alias', 'Bluetooth device'), 'deadline': time.monotonic() + 65}
        self.pending = p
        def connected(value, error):
            if self.pending is p:
                reached = 'AlreadyConnected' if action != 'disconnect' else 'NotConnected'
                self.finish(error_message(error) if error and reached not in str(error) else '', 'paired' if action == 'pair' and error else 'connected')
        def connect():
            self.async_call(path, DEVICE, 'Disconnect' if action == 'disconnect' else 'Connect', None, connected, 20000)
        def paired(value, error):
            if self.pending is not p:
                return
            if error:
                self.finish(error_message(error))
                return
            try:
                state = self.props(path, DEVICE)
                if not (state.get('Paired') or state.get('Bonded')):
                    self.finish('The device did not confirm pairing.')
                    return
            except GLib.Error as exc:
                self.finish(error_message(exc))
                return
            self.clear_prompt()
            def trusted(value, error):
                if self.pending is p:
                    if error:
                        self.finish('Paired, but automatic reconnection could not be enabled. You can connect manually.', 'paired')
                    else:
                        connect()
            self.async_call(path, PROPS, 'Set', GLib.Variant('(ssv)', (DEVICE, 'Trusted', GLib.Variant('b', True))), trusted)
        if action == 'pair':
            if props.get('Paired') or props.get('Bonded'):
                paired(None, None)
            else:
                self.async_call(path, DEVICE, 'Pair', None, paired, 60000)
        else:
            connect()

    def close(self):
        self.cancel()
        # BlueZ also releases this client's discovery and agent when its bus closes.
        self.stop_discovery()
        super().close()


if __name__ == '__main__':
    run(BluetoothService)

#!/usr/bin/env python3
"""Exercise the real helper against a private fake fprintd, never real hardware."""
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading

from gi.repository import Gio, GLib

BUS = 'net.reactivated.Fprint'
MANAGER = '/net/reactivated/Fprint/Manager'
DEVICE = '/net/reactivated/Fprint/Device/0'
IFACE = BUS + '.Device'
FINGER = 'right-index-finger'
xml_manager = '''<node><interface name="net.reactivated.Fprint.Manager"><method name="GetDevices"><arg type="ao" direction="out"/></method></interface></node>'''
xml_device = '''<node><interface name="net.reactivated.Fprint.Device">
<method name="Claim"><arg type="s" direction="in"/></method><method name="Release"/>
<method name="ListEnrolledFingers"><arg type="s" direction="in"/><arg type="as" direction="out"/></method>
<method name="EnrollStart"><arg type="s" direction="in"/></method><method name="EnrollStop"/>
<method name="VerifyStart"><arg type="s" direction="in"/></method><method name="VerifyStop"/>
<method name="DeleteEnrolledFinger"><arg type="s" direction="in"/></method>
<property name="num-enroll-stages" type="i" access="read"/>
<property name="name" type="s" access="read"/>
<property name="finger-needed" type="b" access="read"/>
<property name="finger-present" type="b" access="read"/>
<signal name="EnrollStatus"><arg type="s"/><arg type="b"/></signal>
<signal name="VerifyStatus"><arg type="s"/><arg type="b"/></signal>
</interface></node>'''

class Fixture:
    def __init__(self):
        self.bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        self.calls = []
        self.fingers = []
        self.mode = ''
        self.pending_claim = None
        self.verify_index = 0
        self.bus.register_object(MANAGER, Gio.DBusNodeInfo.new_for_xml(xml_manager).interfaces[0], self.method, None, None)
        self.bus.register_object(DEVICE, Gio.DBusNodeInfo.new_for_xml(xml_device).interfaces[0], self.method, self.prop, None)
        self.bus.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'RequestName',
                           GLib.Variant('(su)', (BUS, 0)), None, Gio.DBusCallFlags.NONE, 3000, None)
    def prop(self, *_args):
        name = _args[-1]
        if name == 'name':
            return GLib.Variant('s', 'fake reader')
        if name in ('finger-needed', 'finger-present'): return GLib.Variant('b', False)
        return GLib.Variant('i', 3)
    def method(self, conn, _sender, path, _iface, method, args, inv):
        values = args.unpack() if args else ()
        self.calls.append((method, values))
        if method == 'Claim' and self.mode == 'delayed_claim':
            self.pending_claim = inv
            return
        if method == 'ListEnrolledFingers' and self.mode == 'owner_lost':
            conn.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'ReleaseName', GLib.Variant('(s)', (BUS,)), None, Gio.DBusCallFlags.NONE, 3000, None)
            GLib.timeout_add(100, lambda: (inv.return_value(GLib.Variant('(as)', ([FINGER],))), False)[1])
            return
        if method == 'GetDevices': inv.return_value(GLib.Variant('(ao)', ([DEVICE],))); return
        if method == 'ListEnrolledFingers':
            if self.fingers: inv.return_value(GLib.Variant('(as)', (self.fingers,)))
            else: inv.return_dbus_error('net.reactivated.Fprint.Error.NoEnrolledPrints', 'no prints')
            return
        if method == 'VerifyStart' and self.mode == 'early':
            conn.emit_signal(None, DEVICE, IFACE, 'VerifyStatus', GLib.Variant('(sb)', ('verify-match', True)))
        if method == 'VerifyStart' and self.mode == 'malformed':
            conn.emit_signal(None, DEVICE, IFACE, 'VerifyStatus', GLib.Variant('(s)', ('verify-match',)))
        if method == 'VerifyStop' and self.mode == 'cleanup_error':
            inv.return_dbus_error('net.reactivated.Fprint.Error.Internal', 'stop failed')
            return
        if method == 'DeleteEnrolledFinger': self.fingers.remove(values[0])
        inv.return_value(GLib.Variant('()', ()))
        if method == 'EnrollStart' and self.mode == 'enroll':
            def presence(present):
                conn.emit_signal(None, DEVICE, 'org.freedesktop.DBus.Properties', 'PropertiesChanged',
                                 GLib.Variant('(sa{sv}as)', (IFACE, {'finger-present': GLib.Variant('b', present)}, [])))
                return False
            GLib.timeout_add(20, presence, True)
            GLib.timeout_add(50, presence, False)
            def enroll():
                conn.emit_signal(None, DEVICE, IFACE, 'EnrollStatus', GLib.Variant('(sb)', ('enroll-stage-passed', False)))
                self.fingers.append(FINGER)
                conn.emit_signal(None, DEVICE, IFACE, 'EnrollStatus', GLib.Variant('(sb)', ('enroll-completed', True)))
                return False
            GLib.timeout_add(80, enroll)
        if method == 'VerifyStart' and self.mode in ('verify', 'cleanup_error', 'malformed'):
            GLib.timeout_add(80, lambda: (conn.emit_signal(None, DEVICE, IFACE, 'VerifyStatus', GLib.Variant('(sb)', ('verify-match', True))), False)[1])


def run(fixture, action, mode, cancel=False):
    fixture.calls.clear(); fixture.mode = mode
    environment = dict(os.environ, DBUS_SYSTEM_BUS_ADDRESS=os.environ['DBUS_SESSION_BUS_ADDRESS'], PATH=fixture.command_path)
    helper = Path(__file__).resolve().parents[2] / 'MacShell/fingerprint_operation.py'
    binary = os.environ.get('MACSHELL_TEST_FINGERPRINT_BINARY')
    command = [binary] if binary else [sys.executable, str(helper)]
    child = subprocess.Popen([*command, action, DEVICE, FINGER], env=environment, stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    lines = queue.Queue()
    def reader():
        for line in child.stdout: lines.put(json.loads(line))
    threading.Thread(target=reader, daemon=True).start()
    messages = []
    while True:
        message = lines.get(timeout=15); messages.append(message)
        if cancel and message.get('code') == 'scan': child.stdin.write('cancel\n'); child.stdin.flush(); cancel = False
        if message.get('type') == 'result': break
    child.wait(timeout=5)
    assert child.returncode == 0, child.stderr.read()
    child.stdin.close(); child.stdout.close(); child.stderr.close()
    return messages


fixture = Fixture()
fake_commands = tempfile.TemporaryDirectory(prefix='fingerprint-polkit-fixture-')
fake_pkcheck = Path(fake_commands.name) / 'pkcheck'
fake_pkcheck.write_text('#!/bin/sh\nexit 0\n')
fake_pkcheck.chmod(0o700)
fixture.command_path = fake_commands.name + os.pathsep + os.environ.get('PATH', '')
loop = GLib.MainLoop()
thread = threading.Thread(target=loop.run, daemon=True); thread.start()
try:
    messages = run(fixture, 'enroll', 'enroll')
    assert messages[-1] == {'type':'result', 'success':True, 'code':'enroll-completed'}, messages
    assert any(m.get('stage') == 1 and m.get('total') == 3 for m in messages), messages
    assert any(m == {'type': 'finger-presence', 'present': True} for m in messages), messages
    assert any(m == {'type': 'finger-presence', 'present': False} for m in messages), messages
    assert [c[0] for c in fixture.calls] == ['GetDevices','Claim','ListEnrolledFingers','EnrollStart','EnrollStop','Release'], fixture.calls
    assert dict(fixture.calls)['Claim'] == ('',) and dict(fixture.calls)['ListEnrolledFingers'] == ('',)
    messages = run(fixture, 'verify', 'verify')
    assert messages[-1]['code'] == 'verify-match', messages
    assert [c[0] for c in fixture.calls][-2:] == ['VerifyStop', 'Release']
    messages = run(fixture, 'verify', 'cancel', cancel=True)
    assert messages[-1]['code'] == 'cancelled', messages
    assert [c[0] for c in fixture.calls][-2:] == ['VerifyStop', 'Release']
    messages = run(fixture, 'verify', 'early')
    assert messages[-1]['code'] == 'verify-match' and messages[-1]['success'], messages
    messages = run(fixture, 'verify', 'cleanup_error')
    assert messages[-1]['code'] == 'verify-match' and messages[-1]['success'] and messages[-1]['cleanupFailed'], messages
    assert [c[0] for c in fixture.calls][-2:] == ['VerifyStop', 'Release']
    messages = run(fixture, 'verify', 'owner_lost')
    assert messages[-1]['code'] == 'service_error', messages
    assert 'VerifyStart' not in [c[0] for c in fixture.calls], fixture.calls
    fixture.bus.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'RequestName', GLib.Variant('(su)', (BUS, 0)), None, Gio.DBusCallFlags.NONE, 3000, None)
    messages = run(fixture, 'delete', 'delete')
    assert messages[-1]['code'] == 'deleted' and fixture.fingers == [], messages
    assert ('DeleteEnrolledFinger', (FINGER,)) in fixture.calls
    if os.environ.get('MACSHELL_TEST_FINGERPRINT_BINARY'):
        fixture.fingers = [FINGER]
        messages = run(fixture, 'verify', 'malformed')
        assert messages[-1]['code'] == 'verify-match', messages
        fixture.calls.clear(); fixture.mode = 'delayed_claim'; fixture.pending_claim = None
        environment = dict(os.environ, DBUS_SYSTEM_BUS_ADDRESS=os.environ['DBUS_SESSION_BUS_ADDRESS'], PATH=fixture.command_path)
        child = subprocess.Popen([os.environ['MACSHELL_TEST_FINGERPRINT_BINARY'], 'verify', DEVICE, FINGER], env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        import time
        deadline = time.monotonic() + 5
        while fixture.pending_claim is None and time.monotonic() < deadline: time.sleep(.01)
        assert fixture.pending_claim is not None, fixture.calls
        child.stdin.write('cancel\n'); child.stdin.flush(); time.sleep(.1)
        GLib.idle_add(lambda: (fixture.pending_claim.return_value(GLib.Variant('()', ())), False)[1])
        output, errors = child.communicate(timeout=5)
        messages = [json.loads(line) for line in output.splitlines()]
        assert messages[-1]['code'] == 'cancelled', (messages, errors)
        assert [c[0] for c in fixture.calls] == ['GetDevices', 'Claim', 'Release'], fixture.calls
    print('MACSHELL_FINGERPRINT_DBUS_PASS: private fprintd enroll, progress, verify, cancel, delete and claim release')
finally:
    loop.quit(); thread.join(timeout=5)
    fake_commands.cleanup()

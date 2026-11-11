"""Power profile protocol against a private D-Bus and synthetic daemon only."""
import json
import os
import queue
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
from gi.repository import Gio, GLib

from test_dbus_protocol import Client
from scripts.install_niri import quickshell
import test_power as fixtures

ROOT=Path(__file__).resolve().parents[1]
BINARY=os.environ.get('MACSHELL_TEST_POWER_PROFILES_BINARY')
class RustClient(Client):
    def __init__(self,address):
        env=dict(os.environ,DBUS_SYSTEM_BUS_ADDRESS=address)
        self.process=subprocess.Popen([BINARY],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,text=True)
        self.queue=queue.Queue(); self.lines=[]; self.sequence=0
        def read():
            for line in self.process.stdout: self.queue.put(json.loads(line))
        self.thread=threading.Thread(target=read,daemon=True); self.thread.start()

class DelayedPowerBus(fixtures.PowerBus):
    def __init__(self):
        self.waiters=[]; self.senders=[]
        super().__init__()
    def method(self,bus,sender,path,iface,method,parameters,invocation):
        if iface==self.name and method=='HoldProfile':
            self.calls.append(method); self.waiters.append(invocation); self.senders.append(sender)
        else:
            super().method(bus,sender,path,iface,method,parameters,invocation)

@unittest.skipUnless(BINARY,'Set MACSHELL_TEST_POWER_PROFILES_BINARY')
class PowerRustTests(fixtures.PowerTests):
    def setUp(self):
        self.bus=fixtures.PowerBus(); self.client=RustClient(self.bus.address)
        self.client.wait(lambda m:m.get('type')=='state' and m.get('profile')=='balanced')
    def test_legacy_service(self):
        self.client.close(); self.bus.close()
        self.bus=fixtures.PowerBus(legacy=True); self.client=RustClient(self.bus.address)
        self.state('balanced'); self.client.send('select',profile='performance'); self.state('performance')
    def test_owner_loss_rejects_late_response_even_when_same_connection_reacquires_name(self):
        self.client.close(); self.bus.close()
        self.bus=DelayedPowerBus(); self.client=RustClient(self.bus.address); self.state('balanced')
        self.client.send('game',enabled=True)
        self.client.wait(lambda m:m.get('type')=='state' and m.get('busy'))
        deadline=time.monotonic()+4
        while len(self.bus.waiters)<1 and time.monotonic()<deadline: time.sleep(.01)
        self.assertEqual(len(self.bus.waiters),1)
        self.bus.connection.call_sync('org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus',
            'ReleaseName',GLib.Variant('(s)',(self.bus.name,)),None,Gio.DBusCallFlags.NONE,1000,None)
        self.client.wait(lambda m:m.get('type')=='unavailable')
        self.client.process.wait(timeout=3)
        old_owner=self.bus.connection.call_sync('org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus',
            'NameHasOwner',GLib.Variant('(s)',(self.bus.senders[0],)),None,Gio.DBusCallFlags.NONE,1000,None).unpack()[0]
        self.assertFalse(old_owner); self.client.close()
        self.bus.connection.call_sync('org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus',
            'RequestName',GLib.Variant('(su)',(self.bus.name,0)),None,Gio.DBusCallFlags.NONE,1000,None)
        self.client=RustClient(self.bus.address); self.state('balanced'); self.client.send('game',enabled=True)
        self.client.wait(lambda m:m.get('type')=='state' and m.get('busy'))
        deadline=time.monotonic()+4
        while len(self.bus.waiters)<2 and time.monotonic()<deadline: time.sleep(.01)
        self.assertEqual(len(self.bus.waiters),2)
        self.bus.waiters[0].return_value(GLib.Variant('(u)',(11,)))
        time.sleep(.2); seen=[]
        while not self.client.queue.empty(): seen.append(self.client.queue.get_nowait())
        self.assertFalse(any(m.get('gameHold') for m in seen),seen)
        self.bus.cookie=42; self.bus.previous='balanced'; self.bus.set_active('performance')
        self.bus.waiters[1].return_value(GLib.Variant('(u)',(42,)))
        self.state('performance',gameHold=True)
    def test_unreachable_bus_is_reported_without_system_fallback(self):
        env=dict(os.environ,DBUS_SYSTEM_BUS_ADDRESS='unix:path=/no-such-macshell-bus')
        result=subprocess.run([BINARY],env=env,capture_output=True,text=True,timeout=5)
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(json.loads(result.stdout)['type'],'unavailable')
    def test_idle_owner_loss_reconnects_without_restarting(self):
        pid=self.client.process.pid
        self.bus.connection.call_sync('org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus',
            'ReleaseName',GLib.Variant('(s)',(self.bus.name,)),None,Gio.DBusCallFlags.NONE,1000,None)
        self.client.wait(lambda m:m.get('type')=='unavailable')
        self.bus.connection.call_sync('org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus',
            'RequestName',GLib.Variant('(su)',(self.bus.name,0)),None,Gio.DBusCallFlags.NONE,1000,None)
        self.state('balanced'); self.assertEqual(self.client.process.pid,pid); self.assertIsNone(self.client.process.poll())
    def test_owner_loss_with_active_hold_closes_the_connection(self):
        self.client.send('game',enabled=True); self.state('performance',gameHold=True)
        self.bus.connection.call_sync('org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus',
            'ReleaseName',GLib.Variant('(s)',(self.bus.name,)),None,Gio.DBusCallFlags.NONE,1000,None)
        self.client.wait(lambda m:m.get('type')=='unavailable'); self.client.process.wait(timeout=3)
    def test_unconfirmed_set_does_not_report_success(self):
        self.bus.ignore_set=True; self.client.send('select',profile='performance')
        state=self.client.wait(lambda m:m.get('type')=='state' and not m.get('busy') and m.get('error'))
        self.assertEqual(state['profile'],'balanced')
        self.assertIn('did not activate',state['error'])
    def test_inhibited_game_mode_never_requests_a_hold(self):
        self.bus.props[(self.bus.path,self.bus.name)]['PerformanceInhibited']=GLib.Variant('s','thermal')
        self.bus.changed(); self.state('balanced',inhibited='thermal')
        self.client.send('game',enabled=True)
        state=self.client.wait(lambda m:m.get('type')=='state' and m.get('error') and not m.get('busy'))
        self.assertFalse(state['gameHold']); self.assertEqual(self.bus.calls,[])
    def test_malformed_release_signal_is_ignored(self):
        self.client.send('game',enabled=True); self.state('performance',gameHold=True)
        self.bus.connection.emit_signal(None,self.bus.path,self.bus.name,'ProfileReleased',GLib.Variant('(s)',('invalid',)))
        self.bus.changed(); self.state('performance',gameHold=True)
        self.client.send('game',enabled=False); self.state('balanced',gameHold=False)
    def test_timed_out_hold_is_not_treated_as_owned(self):
        self.client.close(); self.bus.close()
        self.bus=DelayedPowerBus(); self.client=RustClient(self.bus.address); self.state('balanced')
        self.client.send('game',enabled=True)
        state=self.client.wait(lambda m:m.get('type')=='unavailable' and m.get('error'),timeout=19)
        self.assertEqual(self.bus.calls,['HoldProfile']); self.assertTrue(state['error'])
        self.client.process.wait(timeout=3)
        owner=self.bus.connection.call_sync('org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus',
            'NameHasOwner',GLib.Variant('(s)',(self.bus.senders[0],)),None,Gio.DBusCallFlags.NONE,1000,None).unpack()[0]
        self.assertFalse(owner)
    def test_failed_release_closes_the_owning_connection(self):
        self.client.send('game',enabled=True); self.state('performance',gameHold=True)
        self.bus.reject_release=True; self.client.send('game',enabled=False)
        state=self.client.wait(lambda m:m.get('type')=='unavailable' and m.get('error'))
        self.assertTrue(state['error']); self.client.process.wait(timeout=3)
        self.assertEqual(self.bus.calls,['HoldProfile','ReleaseProfile'])
    def test_failed_release_does_not_apply_manual_profile(self):
        self.client.send('game',enabled=True); self.state('performance',gameHold=True)
        self.bus.reject_release=True; self.client.send('select',profile='power-saver')
        self.client.wait(lambda m:m.get('type')=='unavailable' and m.get('error'))
        self.client.process.wait(timeout=3)
        self.assertEqual(self.bus.props[(self.bus.path,self.bus.name)]['ActiveProfile'].unpack(),'performance')
        self.assertEqual(self.bus.calls,['HoldProfile','ReleaseProfile'])
    def test_process_closes_cleanly_with_a_pending_hold(self):
        self.client.close(); self.bus.close()
        self.bus=DelayedPowerBus(); self.client=RustClient(self.bus.address); self.state('balanced')
        self.client.send('game',enabled=True); self.client.wait(lambda m:m.get('type')=='state' and m.get('busy'))
        self.client.close()
        # The standard cleanup will close a fresh client connected only to the private bus.
        self.client=RustClient(self.bus.address); self.state('balanced')
    def test_launcher_prefers_compatible_binary_and_falls_back(self):
        with tempfile.TemporaryDirectory(prefix='macshell-power-launcher-') as temp:
            root=Path(temp); shutil.copy(ROOT/'MacShell/power-profiles.sh',root/'power-profiles.sh')
            (root/'power_control.py').write_text('print("legacy")\n')
            binary=root/'power-profiles-rust'
            binary.write_text('#!/bin/sh\nif [ "${1-}" = --protocol-version ]; then echo "macshell-power-profiles 1"; else echo rust; fi\n'); binary.chmod(0o755)
            def launch(check=True):
                return subprocess.run(['sh',str(root/'power-profiles.sh')],capture_output=True,text=True,timeout=5,check=check)
            self.assertEqual(launch().stdout.strip(),'rust')
            binary.write_text('#!/bin/sh\necho wrong\n')
            incompatible = launch(check=False)
            self.assertNotEqual(incompatible.returncode, 0)
            self.assertNotIn('legacy', incompatible.stdout)
            self.assertIn('Rust', incompatible.stderr)
            binary.unlink()
            missing = launch(check=False)
            self.assertNotEqual(missing.returncode, 0)
            self.assertNotIn('legacy', missing.stdout)
    @unittest.skipUnless(shutil.which(quickshell()),'Quickshell is required')
    def test_qml_uses_rust_with_private_dbus(self):
        with tempfile.TemporaryDirectory(prefix='macshell-power-qml-') as temp:
            root=Path(temp); shell=root/'shell'; shutil.copytree(ROOT/'MacShell',shell)
            shutil.copy(ROOT/'tests/power-profiles-rust.qml',shell/'shell.qml')
            shutil.copy(BINARY,shell/'power-profiles-rust')
            (shell/'power_control.py').write_text('raise SystemExit("unexpected Python fallback")\n')
            for name in ('runtime','config','cache'): (root/name).mkdir()
            (root/'runtime').chmod(0o700)
            env=dict(os.environ,DBUS_SYSTEM_BUS_ADDRESS=self.bus.address,XDG_RUNTIME_DIR=str(root/'runtime'),
                     XDG_CONFIG_HOME=str(root/'config'),XDG_CACHE_HOME=str(root/'cache'),
                     QT_QPA_PLATFORM='offscreen',QT_QPA_PLATFORMTHEME='',QT_QUICK_BACKEND='software',
                     DBUS_SESSION_BUS_ADDRESS='unix:path='+str(root/'no-bus'))
            env.pop('DISPLAY',None); env.pop('WAYLAND_DISPLAY',None)
            result=subprocess.run([quickshell(),'-p',str(shell)],env=env,capture_output=True,text=True,timeout=16)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertIn('POWER_RUST_QML_PASS',result.stdout+result.stderr)
            self.assertEqual(self.bus.calls,['HoldProfile','ReleaseProfile'])

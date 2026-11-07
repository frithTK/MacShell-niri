"""Exercise Rust Agent1 over a private D-Bus; never connect to real BlueZ."""
import json
import os
from pathlib import Path
import queue
import subprocess
import threading
import time
import unittest
from gi.repository import Gio,GLib
from test_dbus_protocol import PrivateBus

BINARY=os.environ.get('MACSHELL_TEST_BLUEZ_AGENT_HARNESS')
PATH='/org/macshell/BluetoothAgent'; IFACE='org.bluez.Agent1'
DEVICE='/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF'

class Harness:
    def __init__(self,address):
        self.process=subprocess.Popen([BINARY],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                                      env=dict(os.environ,DBUS_SYSTEM_BUS_ADDRESS=address),text=True)
        self.messages=queue.Queue(); self.lines=[];self.serial=0
        def read():
            for line in self.process.stdout:self.messages.put(json.loads(line))
        self.thread=threading.Thread(target=read,daemon=True);self.thread.start()
        self.ready=self.wait(lambda m:m.get('type')=='ready')
    def send(self,action,**data):
        self.serial+=1;request={'action':action,'id':self.serial,**data}
        self.process.stdin.write(json.dumps(request)+'\n');self.process.stdin.flush();return self.serial
    def wait(self,predicate,timeout=4):
        deadline=time.monotonic()+timeout
        while time.monotonic()<deadline:
            try: message=self.messages.get(timeout=.1)
            except queue.Empty: continue
            self.lines.append(message)
            if predicate(message):return message
        raise AssertionError('No expected response: '+repr(self.lines[-6:]))
    def close(self):
        self.process.stdin.close();self.process.wait(timeout=5);self.thread.join(timeout=2)
        error=self.process.stderr.read();self.process.stdout.close();self.process.stderr.close()
        if error:raise AssertionError(error)

@unittest.skipUnless(BINARY,'Set MACSHELL_TEST_BLUEZ_AGENT_HARNESS')
class BluezAgentRustTests(unittest.TestCase):
    def setUp(self):
        self.bus=PrivateBus(); self.harness=Harness(self.bus.address)
    def tearDown(self):
        try:self.harness.close()
        finally:self.bus.close()
    def begin(self):
        request=self.harness.send('begin',device=DEVICE);self.harness.wait(lambda m:m.get('type')=='begun');return request
    def call(self,connection,method,signature,args):
        finished=queue.Queue()
        def callback(bus,result):
            try:finished.put(('ok',bus.call_finish(result).unpack()))
            except GLib.Error as error:finished.put(('error',str(error)))
        connection.call(self.harness.ready['unique'],PATH,IFACE,method,GLib.Variant(signature,args),None,
                        Gio.DBusCallFlags.NONE,4000,None,callback)
        return finished
    def test_confirmation_requires_matching_user_response(self):
        request=self.begin();result=self.call(self.bus.connection,'RequestConfirmation','(ou)',(DEVICE,42))
        prompt=self.harness.wait(lambda m:m.get('type')=='prompt')
        self.assertEqual(prompt['request'],request);self.assertEqual(prompt['code'],'000042');self.assertTrue(prompt['deferred'])
        self.harness.send('respond',prompt=prompt['id']+1,accept=True)
        self.assertEqual(self.harness.wait(lambda m:m.get('type')=='response')['result'],'ignored');self.assertTrue(result.empty())
        self.harness.send('respond',prompt=prompt['id'],accept=True)
        self.assertEqual(self.harness.wait(lambda m:m.get('type')=='response')['result'],'accepted')
        self.assertEqual(result.get(timeout=3),('ok',()))
    def test_pin_and_passkey_reject_invalid_values_then_accept(self):
        self.begin()
        for method,invalid,valid,expected in [('RequestPinCode','я'*9,'001234',('001234',)),('RequestPasskey','1234567','000042',(42,))]:
            with self.subTest(method=method):
                result=self.call(self.bus.connection,method,'(o)',(DEVICE,));prompt=self.harness.wait(lambda m:m.get('type')=='prompt' and m.get('method')==method)
                self.harness.send('respond',prompt=prompt['id'],accept=True,value=invalid)
                self.harness.wait(lambda m:m.get('type')=='error');self.assertTrue(result.empty())
                self.harness.send('respond',prompt=prompt['id'],accept=True,value=valid)
                self.harness.wait(lambda m:m.get('type')=='response');self.assertEqual(result.get(timeout=3),('ok',expected))
    def test_unknown_sender_and_unrequested_device_are_rejected(self):
        self.begin(); attacker=Gio.DBusConnection.new_for_address_sync(self.bus.address,Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT|Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,None,None)
        try:
            for connection,device in ((attacker,DEVICE),(self.bus.connection,'/org/bluez/hci0/dev_00_00_00_00_00_00')):
                result=self.call(connection,'RequestAuthorization','(o)',(device,)).get(timeout=3)
                self.assertEqual(result[0],'error');self.assertIn('org.bluez.Error.Rejected',result[1])
        finally:attacker.close_sync(None)
    def test_new_prompt_cancels_prior_invocation_and_display_returns_immediately(self):
        self.begin();first=self.call(self.bus.connection,'RequestAuthorization','(o)',(DEVICE,))
        self.harness.wait(lambda m:m.get('type')=='prompt')
        second=self.call(self.bus.connection,'DisplayPasskey','(ouq)',(DEVICE,42,3))
        prompt=self.harness.wait(lambda m:m.get('type')=='prompt' and m.get('method')=='DisplayPasskey')
        self.assertEqual(prompt['code'],'000042');self.assertEqual(prompt['entered'],3);self.assertFalse(prompt['deferred'])
        self.assertEqual(first.get(timeout=3)[0],'error');self.assertEqual(second.get(timeout=3),('ok',()))
    def test_owner_reset_and_cancel_complete_deferred_invocation(self):
        request=self.begin();result=self.call(self.bus.connection,'RequestPinCode','(o)',(DEVICE,))
        self.harness.wait(lambda m:m.get('type')=='prompt');self.harness.send('reset',owner=self.harness.ready['owner'])
        self.harness.wait(lambda m:m.get('type')=='reset');event=self.harness.wait(lambda m:m.get('type')=='owner-reset' and m.get('failed')==request)
        self.assertTrue(event['cancelPrompt']);self.assertIn('Canceled',result.get(timeout=3)[1])
    def test_pair_reply_cannot_leave_deferred_invocation_behind(self):
        self.begin();result=self.call(self.bus.connection,'RequestAuthorization','(o)',(DEVICE,))
        self.harness.wait(lambda m:m.get('type')=='prompt');self.harness.send('paired',confirmed=True)
        step=self.harness.wait(lambda m:m.get('type')=='paired');self.assertIn('Trust',step['step']);self.assertIn('cancel_prompt: true',step['step'])
        self.assertEqual(result.get(timeout=3)[0],'error')
    def test_bluez_cancel_and_release_complete_invocations(self):
        request=self.begin(); pending=self.call(self.bus.connection,'RequestAuthorization','(o)',(DEVICE,))
        self.harness.wait(lambda m:m.get('type')=='prompt')
        cancel=self.call(self.bus.connection,'Cancel','()',())
        self.assertEqual(cancel.get(timeout=3),('ok',()));self.assertEqual(pending.get(timeout=3)[0],'error')
        self.harness.send('cancel',id=request);self.harness.wait(lambda m:m.get('type')=='cancel')
        release=self.call(self.bus.connection,'Release','()',())
        self.assertEqual(release.get(timeout=3),('ok',()));self.harness.wait(lambda m:m.get('type')=='released')
        self.harness.send('begin',device=DEVICE);self.harness.wait(lambda m:m.get('type')=='error')
    def test_shutdown_rejects_pending_invocation(self):
        self.begin(); pending=self.call(self.bus.connection,'RequestPinCode','(o)',(DEVICE,))
        self.harness.wait(lambda m:m.get('type')=='prompt');self.harness.close()
        self.assertEqual(pending.get(timeout=3)[0],'error')
        self.harness=Harness(self.bus.address)

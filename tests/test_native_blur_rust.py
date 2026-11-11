"""Native blur compatibility and safety checks with a fake niri only."""
import os
import fcntl
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'MacShell'))
import native_blur as python_blur
from test_system_stats_rust import Client
from scripts.install_niri import quickshell

BINARY=os.environ.get('MACSHELL_TEST_NATIVE_BLUR_BINARY')
@unittest.skipUnless(BINARY,'Set MACSHELL_TEST_NATIVE_BLUR_BINARY')
class NativeBlurRustTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='macshell-blur-test-'); self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name); self.profile=self.root/'profile'; self.profile.mkdir()
        self.config=self.profile/'config.kdl'; self.fragment=self.profile/'macshell-blur.kdl'
        self.original=b'include "./user.kdl"\nblur { noise 0.1; saturation 1.2; off; }\n'
        self.config.write_bytes(self.original); (self.profile/'user.kdl').write_text('layout { gaps 10; }\n')
        self.socket=str(self.root/'niri.sock'); self.bin=self.root/'bin'; self.bin.mkdir()
        shutil.copy(ROOT/'tests/fixtures/native_blur_validator.py',self.bin/'niri'); (self.bin/'niri').chmod(0o755)
        self.env=dict(os.environ,MACSHELL_NIRI_PROFILE=str(self.profile),NIRI_SOCKET=self.socket,
                      BLUR_TEST_PROFILE=str(self.profile),PATH=str(self.bin)+os.pathsep+os.environ.get('PATH',''))
        self.peer=subprocess.Popen([sys.executable,'-u',str(ROOT/'tests/fixtures/native_blur_niri.py'),
                                    '--config',str(self.config),'--socket',self.socket],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        self.addCleanup(self.stop_peer); self.assertEqual(self.peer.stdout.readline().strip(),'ready')
    def stop_peer(self):
        if self.peer.poll() is None: self.peer.terminate()
        self.peer.wait(timeout=5); self.peer.stdout.close(); self.peer.stderr.close()
    def start(self,python=False,**env):
        command=[sys.executable,'-u',str(ROOT/'MacShell/native_blur.py')] if python else [BINARY]
        client=Client(command,env=dict(self.env,**env)); self.addCleanup(client.close)
        client.message(lambda m:m.get('type')=='ready'); return client
    def request(self,client,action='inspect',data=None):
        client.send({'action':action,'data':data or {},'id':1,'generation':7})
        return client.message(lambda m:m.get('type')=='state',timeout=8)
    def test_apply_matches_python_and_noop_is_quiet(self):
        rust=self.start(); python=self.start(True)
        self.assertEqual(self.request(rust),self.request(python))
        state=self.request(rust,'apply',{'level':80}); self.assertTrue(state['available']); self.assertEqual(state['level'],80)
        self.assertEqual(self.fragment.read_text(),python_blur.blur_config(80)); final=self.config.read_bytes()
        self.assertTrue(final.startswith(self.original)); self.assertEqual(final.count(b'include "./macshell-blur.kdl"'),1)
        self.assertEqual((self.profile/'macshell-blur-config.before').read_bytes(),self.original)
        mtime=self.fragment.stat().st_mtime_ns; self.assertEqual(self.request(rust,'apply',{'level':80}),state)
        self.assertEqual(self.fragment.stat().st_mtime_ns,mtime); self.assertEqual((self.profile/'validator.log').read_text().count('validate'),1)
        self.assertEqual(self.request(python),state)
        self.assertEqual(self.request(rust,'apply',{'level':0})['level'],0)
        self.assertEqual(self.fragment.read_text(),python_blur.blur_config(0))
        self.assertEqual(self.config.read_bytes(),final)
    def test_rounding_and_invalid_levels(self):
        rust=self.start()
        for value in (-5,0.5,1.5,2.5,79.5,500,'3.5'):
            with self.subTest(value=value):
                state=self.request(rust,'apply',{'level':value}); self.assertTrue(state['available'])
                self.assertEqual(self.fragment.read_text(),python_blur.blur_config(float(value)))
        before=self.fragment.read_bytes()
        for value in ('nan','inf','oops',None,[],{}):
            state=self.request(rust,'apply',{'level':value}); self.assertFalse(state['available']); self.assertEqual(self.fragment.read_bytes(),before)
    def test_failed_validation_and_external_changes_keep_originals(self):
        for mode in ('reject','edit-config','edit-fragment','replace-socket'):
            with self.subTest(mode=mode):
                if mode=='replace-socket': pass
                self.config.write_bytes(self.original)
                if self.fragment.exists(): self.fragment.unlink()
                rust=self.start(BLUR_TEST_MODE=mode); state=self.request(rust,'apply',{'level':50})
                self.assertFalse(state['available'])
                if mode=='edit-config': self.assertEqual(self.config.read_bytes(),self.original+b'// external edit\n')
                else: self.assertEqual(self.config.read_bytes(),self.original)
                if mode=='edit-fragment': self.assertEqual(self.fragment.read_text(),'// external fragment\n')
                else: self.assertFalse(self.fragment.exists())
                self.assertFalse(list(self.profile.glob('.macshell-blur-check-*')))
    def test_unowned_fragment_and_symlink_are_not_modified(self):
        rust=self.start(); self.fragment.write_text('// manually edited\n')
        self.assertFalse(self.request(rust,'apply',{'level':12})['available']); self.assertEqual(self.config.read_bytes(),self.original)
        target=self.root/'external'; target.write_text('private'); self.fragment.unlink(); self.fragment.symlink_to(target)
        self.assertFalse(self.request(rust,'apply',{'level':12})['available']); self.assertEqual(target.read_text(),'private')
    def test_unrelated_profile_and_missing_socket_cannot_write(self):
        other=self.root/'other'; other.mkdir(); (other/'config.kdl').write_text('other')
        rust=self.start(MACSHELL_NIRI_PROFILE=str(other)); state=self.request(rust,'apply',{'level':40})
        self.assertFalse(state['available']); self.assertEqual(self.config.read_bytes(),self.original); self.assertFalse(self.fragment.exists())
        self.peer.terminate(); self.peer.wait(timeout=5)
        rust=self.start(); self.assertFalse(self.request(rust,'apply',{'level':40})['available']); self.assertFalse(self.fragment.exists())
    def test_busy_writer_and_lock_symlink_do_not_modify_config(self):
        rust=self.start(); lock=self.profile/'.macshell-blur.lock'
        with lock.open('w') as stream:
            fcntl.flock(stream,fcntl.LOCK_EX)
            state=self.request(rust,'apply',{'level':40})
            self.assertFalse(state['available']); self.assertIn('in progress',state['error'])
            self.assertEqual(self.config.read_bytes(),self.original); self.assertFalse(self.fragment.exists())
        lock.unlink(); target=self.root/'external-lock'; target.write_text('private'); lock.symlink_to(target)
        self.assertFalse(self.request(rust,'apply',{'level':40})['available'])
        self.assertEqual(target.read_text(),'private'); self.assertEqual(self.config.read_bytes(),self.original)
    def test_stalled_validator_times_out_without_writing(self):
        rust=self.start(BLUR_TEST_MODE='hang'); state=self.request(rust,'apply',{'level':40})
        self.assertFalse(state['available']); self.assertEqual(self.config.read_bytes(),self.original); self.assertFalse(self.fragment.exists())
        self.assertFalse(list(self.profile.glob('.macshell-blur-check-*')))
    @unittest.skipUnless(shutil.which('niri'),'niri is required')
    def test_real_niri_validates_an_isolated_candidate(self):
        rust=self.start(PATH=os.environ.get('PATH',''))
        state=self.request(rust,'apply',{'level':24})
        self.assertTrue(state['available'],state['error']); self.assertEqual(state['level'],24)
        result=subprocess.run([shutil.which('niri'),'validate','-c',str(self.config)],capture_output=True,text=True,timeout=6)
        self.assertEqual(result.returncode,0,result.stderr)
    def test_owned_validator_exits_when_service_is_killed(self):
        client=Client([BINARY],env=dict(self.env,BLUR_TEST_MODE='hang'))
        client.message(lambda m:m.get('type')=='ready')
        client.send({'action':'apply','data':{'level':25},'id':1,'generation':7})
        pidfile=self.profile/'validator.pid'; deadline=time.monotonic()+5
        while not pidfile.exists() and time.monotonic()<deadline: time.sleep(.01)
        self.assertTrue(pidfile.exists()); pid=int(pidfile.read_text())
        client.process.kill(); client.process.wait(timeout=5)
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            try: state=Path(f'/proc/{pid}/stat').read_text().rsplit(') ',1)[1].split()[0]
            except FileNotFoundError: break
            if state=='Z': break
            time.sleep(.02)
        else: self.fail('validator survived its owner')
        client.close(); self.assertEqual(self.config.read_bytes(),self.original); self.assertFalse(self.fragment.exists())
    def test_launcher_prefers_compatible_binary_and_falls_back(self):
        folder=self.root/'launcher'; folder.mkdir()
        shutil.copy(ROOT/'MacShell/native-blur.sh',folder/'native-blur.sh')
        (folder/'native_blur.py').write_text('print("legacy")\n')
        binary=folder/'native-blur-rust'
        binary.write_text('#!/bin/sh\nif [ "${1-}" = --protocol-version ]; then echo "macshell-native-blur 1"; else echo rust; fi\n'); binary.chmod(0o755)
        def launch(check=True):
            return subprocess.run(['sh',str(folder/'native-blur.sh')],env=self.env,capture_output=True,text=True,timeout=5,check=check)
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
    def test_qml_applies_blur_only_to_fake_profile(self):
        shell=self.root/'shell'; shutil.copytree(ROOT/'MacShell',shell)
        shutil.copy(ROOT/'tests/native-blur-rust.qml',shell/'shell.qml')
        shutil.copy(BINARY,shell/'native-blur-rust')
        (shell/'native_blur.py').write_text('raise SystemExit("unexpected Python fallback")\n')
        for name in ('runtime','config','cache'): (self.root/name).mkdir()
        (self.root/'runtime').chmod(0o700)
        env=dict(self.env,XDG_RUNTIME_DIR=str(self.root/'runtime'),XDG_CONFIG_HOME=str(self.root/'config'),
                 XDG_CACHE_HOME=str(self.root/'cache'),QT_QPA_PLATFORM='offscreen',QT_QPA_PLATFORMTHEME='',
                 QT_QUICK_BACKEND='software',DBUS_SESSION_BUS_ADDRESS='unix:path='+str(self.root/'no-bus'))
        env.pop('DISPLAY',None); env.pop('WAYLAND_DISPLAY',None)
        result=subprocess.run([quickshell(),'-p',str(shell)],env=env,capture_output=True,text=True,timeout=16)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('NATIVE_BLUR_RUST_QML_PASS',result.stdout+result.stderr)
        self.assertEqual(self.fragment.read_text(),python_blur.blur_config(24))

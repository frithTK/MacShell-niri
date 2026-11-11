"""Session preflight checks with temporary files and isolated fake programs."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT=Path(__file__).resolve().parents[1]
from scripts.install_niri import quickshell
BINARY=os.environ.get('MACSHELL_TEST_PREFLIGHT_BINARY')

@unittest.skipUnless(BINARY,'Set MACSHELL_TEST_PREFLIGHT_BINARY')
class SessionPreflightRustTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='macshell-preflight-test-'); self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name); self.bin=self.root/'bin'; self.bin.mkdir(); self.scratch=self.root/'scratch'; self.scratch.mkdir()
        for name in ('niri','qs'):
            shutil.copy(ROOT/'tests/fixtures/session_preflight_probe.py',self.bin/name); (self.bin/name).chmod(0o755)
        self.config=self.root/'config with spaces.kdl'; self.config.write_text('layout { gaps 10; }\n')
        self.qs=self.bin/'qs'
        self.env=dict(os.environ,PATH=str(self.bin)+os.pathsep+os.environ.get('PATH',''),TMPDIR=str(self.scratch),
                      PREFLIGHT_TEST_ROOT=str(self.root),DISPLAY=':spoof',WAYLAND_DISPLAY='wayland-spoof',
                      QT_QPA_PLATFORMTHEME='gtk3',DBUS_SESSION_BUS_ADDRESS='unix:path=/do-not-use')
    def run_preflight(self,**extra):
        return subprocess.run([BINARY,str(self.config),str(self.qs)],env=dict(self.env,**extra),capture_output=True,text=True,timeout=14)
    def test_valid_probe_is_isolated_and_cleans_temp_files(self):
        result=self.run_preflight(); self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('configuration and Quickshell runtime are ready',result.stdout)
        self.assertEqual(json.loads((self.root/'niri-call.json').read_text()),['validate','-c',str(self.config)])
        data=json.loads((self.root/'qs-call.json').read_text())
        self.assertIn('import Quickshell',data['probe']); self.assertEqual(data['runtimeMode'],0o700)
        self.assertEqual((data['qpa'],data['theme'],data['style']),('offscreen','','Basic'))
        self.assertIsNone(data['display']); self.assertIsNone(data['wayland'])
        self.assertTrue(data['runtime'].startswith(str(self.scratch))); self.assertTrue(data['cache'].startswith(str(self.scratch)))
        self.assertEqual(data['dbus'],'unix:path='+data['cache']+'/no-bus'); self.assertEqual(list(self.scratch.iterdir()),[])
    def test_unavailable_tmpdir_uses_the_next_temporary_directory(self):
        result=self.run_preflight(TMPDIR=str(self.root/'missing'),TEMP=str(self.scratch))
        self.assertEqual(result.returncode,0,result.stderr)
        data=json.loads((self.root/'qs-call.json').read_text())
        self.assertTrue(data['runtime'].startswith(str(self.scratch))); self.assertEqual(list(self.scratch.iterdir()),[])
    def test_invalid_config_does_not_launch_runtime(self):
        for mode in ('fail','invalid-utf8'):
            with self.subTest(mode=mode):
                result=self.run_preflight(PREFLIGHT_NIRI_MODE=mode)
                self.assertNotEqual(result.returncode,0)
                self.assertFalse((self.root/'qs-call.json').exists()); self.assertEqual(list(self.scratch.iterdir()),[])
    def test_runtime_failure_and_abi_warnings_are_rejected(self):
        for mode in ('fail','mismatch','loadfail','flood','invalid-utf8'):
            with self.subTest(mode=mode):
                result=self.run_preflight(PREFLIGHT_QS_MODE=mode)
                self.assertNotEqual(result.returncode,0); self.assertEqual(list(self.scratch.iterdir()),[])
    def test_timeout_kills_owned_process_group(self):
        result=self.run_preflight(PREFLIGHT_QS_MODE='hang')
        self.assertNotEqual(result.returncode,0); self.assertIn('timed out',result.stderr)
        for name in ('parent.pid','child.pid'):
            pid=int((self.root/name).read_text()); deadline=time.monotonic()+3
            while time.monotonic()<deadline:
                try: state=Path(f'/proc/{pid}/stat').read_text().rsplit(') ',1)[1].split()[0]
                except FileNotFoundError: break
                if state=='Z': break
                time.sleep(.02)
            else: self.fail(f'{name} survived the timed-out preflight')
        self.assertEqual(list(self.scratch.iterdir()),[])
    def test_launcher_selects_rust_or_python_fallback(self):
        folder=self.root/'launcher'; folder.mkdir(); shutil.copy(ROOT/'scripts/session-preflight.sh',folder/'session-preflight.sh')
        (folder/'session-preflight.py').write_text('print("legacy", *__import__("sys").argv[1:])\n')
        binary=folder/'session-preflight-rust'
        binary.write_text('#!/bin/sh\nif [ "${1-}" = --protocol-version ]; then echo "macshell-session-preflight 1"; else echo "rust $*"; fi\n'); binary.chmod(0o755)
        def launch(check=True):
            return subprocess.run(['sh',str(folder/'session-preflight.sh'),'config','qs'],env=self.env,capture_output=True,text=True,timeout=5,check=check)
        self.assertEqual(launch().stdout.strip(),'rust config qs')
        binary.write_text('#!/bin/sh\necho wrong\n')
        incompatible = launch(check=False)
        self.assertNotEqual(incompatible.returncode, 0)
        self.assertNotIn('legacy', incompatible.stdout)
        self.assertIn('Rust', incompatible.stderr)
        binary.unlink()
        missing = launch(check=False)
        self.assertNotEqual(missing.returncode, 0)
        self.assertNotIn('legacy', missing.stdout)
    def test_ready_launcher_requires_specific_protocol(self):
        folder=self.root/'ready'; folder.mkdir(); shutil.copy(ROOT/'scripts/session-ready.sh',folder/'session-ready.sh')
        (folder/'session-ready.py').write_text('print("legacy", *__import__("sys").argv[1:])\n')
        binary=folder/'session-preflight-rust'
        binary.write_text('#!/bin/sh\nif [ "${1-}" = --ready-protocol-version ]; then echo "macshell-session-ready 1"; else echo "rust $*"; fi\n'); binary.chmod(0o755)
        def launch(check=True):
            return subprocess.run(['sh',str(folder/'session-ready.sh'),'launcher path'],env=self.env,capture_output=True,text=True,timeout=5,check=check)
        self.assertEqual(launch().stdout.strip(),'rust --ready launcher path')
        binary.write_text('#!/bin/sh\necho "macshell-session-preflight 1"\n')
        refused = launch(check=False)
        self.assertNotEqual(refused.returncode, 0)
        self.assertNotIn('legacy', refused.stdout)
        self.assertIn('Rust', refused.stderr)
    def test_session_check_invokes_installed_preflight_without_starting_session(self):
        folder=self.root/'profile with spaces'; folder.mkdir()
        shutil.copy(ROOT/'scripts/session-preflight.sh',folder/'session-preflight.sh')
        (folder/'session-preflight.sh').chmod(0o755)
        shutil.copy(BINARY,folder/'session-preflight-rust')
        (folder/'session-preflight.py').write_text('raise SystemExit("unexpected Python fallback")\n')
        source=(ROOT/'scripts/niri-macshell-session.sh').read_text()
        for key,value in {'@PROFILE_CONFIG@':self.config,'@PREFLIGHT@':folder/'session-preflight.sh',
                          '@QS_BINARY@':self.qs,'@LOCALE_HELPER@':folder/'unused'}.items():
            source=source.replace(key,shlex.quote(str(value)))
        script=self.root/'entry.sh'; script.write_text(source)
        result=subprocess.run(['bash',str(script),'--check'],env=self.env,capture_output=True,text=True,timeout=15)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('Quickshell runtime are ready',result.stdout)
        self.assertFalse((self.root/'state/macshell-niri/session.log').exists())
    @unittest.skipUnless(shutil.which('niri') and shutil.which(quickshell()),'niri and Quickshell are required')
    def test_real_niri_and_qs_offscreen(self):
        env=dict(self.env,PATH=os.environ.get('PATH',''))
        result=subprocess.run([BINARY,str(ROOT/'config/macshell.kdl'),quickshell()],env=env,capture_output=True,text=True,timeout=24)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr); self.assertEqual(list(self.scratch.iterdir()),[])

"""Color picker compatibility using only synthetic niri, clipboard and notifications."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from scripts.install_niri import quickshell

ROOT=Path(__file__).resolve().parents[1]
BINARY=os.environ.get('MACSHELL_TEST_NIRI_COLOR_BINARY')
@unittest.skipUnless(BINARY,'Set MACSHELL_TEST_NIRI_COLOR_BINARY')
class NiriColorRustTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='macshell-color-test-'); self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name); self.bin=self.root/'bin'; self.bin.mkdir()
        for name in ('niri','wl-copy','notify-send'):
            shutil.copy(ROOT/'tests/fixtures/niri_color_program.py',self.bin/name); (self.bin/name).chmod(0o755)
        self.env=dict(os.environ,PATH=str(self.bin)+os.pathsep+os.environ.get('PATH',''),COLOR_TEST_ROOT=str(self.root))
    def events(self):
        path=self.root/'events.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
    def execute(self,reply,python=False,**settings):
        path=self.root/'events.jsonl'; path.unlink(missing_ok=True)
        command=[sys.executable,'-u',str(ROOT/'MacShell/niri_tools.py'),'color'] if python else [BINARY]
        result=subprocess.run(command,env=dict(self.env,COLOR_REPLY=reply,**settings),capture_output=True,text=True,timeout=8)
        return result,self.events()
    def test_valid_shapes_match_python_and_use_no_extra_commands(self):
        for response in ({'rgb':{'r':.2,'g':.5,'b':1}},{'rgb':[0,.25,.75]},
                         {'color':{'r':1,'b':.2}},{'r':-.2,'g':2,'b':.5}, {'rgb':[], 'color':[1,0,.5]}):
            with self.subTest(response=response):
                raw=json.dumps(response); rust,actual=self.execute(raw); python,expected=self.execute(raw,python=True)
                self.assertEqual(rust.returncode,0,rust.stderr); self.assertEqual(python.returncode,0,python.stderr)
                self.assertEqual(actual,expected)
                self.assertEqual([event['program'] for event in actual],['niri','wl-copy','notify-send'])
    def test_cancellation_does_not_touch_clipboard_or_notify(self):
        for raw in ('null','{}','false','[]','0','""'):
            result,events=self.execute(raw); self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual([event['program'] for event in events],['niri'])
    def test_bad_response_failures_and_oversized_data_do_not_copy(self):
        for raw,options in [('broken',{}),('{"rgb":[0,1]}',{}),('{"rgb":[1e308,0,0]}',{}),('null',{'COLOR_TEST_MODE':'fail'}),('null',{'COLOR_TEST_MODE':'flood'}),('null',{'COLOR_TEST_MODE':'stderr-flood'})]:
            with self.subTest(raw=raw,options=options):
                result,events=self.execute(raw,**options); self.assertNotEqual(result.returncode,0)
                self.assertNotIn('wl-copy',[event['program'] for event in events])
                self.assertEqual(events[-1]['program'],'notify-send'); self.assertEqual(events[-1]['args'][0],'MacShell')
    def test_copy_failure_reports_error_without_success_notification(self):
        result,events=self.execute('{"rgb":[1,0,0]}',COLOR_COPY_FAIL='1')
        self.assertNotEqual(result.returncode,0); self.assertEqual([e['program'] for e in events],['niri','wl-copy','notify-send'])
        self.assertEqual(events[-1]['args'][0],'MacShell')
    def test_picker_waits_for_user_and_child_exits_with_owner(self):
        started=time.monotonic(); result,events=self.execute('{"rgb":[1,0,0]}',COLOR_TEST_MODE='slow')
        self.assertEqual(result.returncode,0,result.stderr); self.assertGreaterEqual(time.monotonic()-started,.25)
        process=subprocess.Popen([BINARY],env=dict(self.env,COLOR_TEST_MODE='wait'),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        try:
            pidfile=self.root/'picker.pid'; deadline=time.monotonic()+5
            while not pidfile.exists() and time.monotonic()<deadline: time.sleep(.01)
            self.assertTrue(pidfile.exists()); pid=int(pidfile.read_text())
            process.kill(); process.wait(timeout=5); deadline=time.monotonic()+4
            while time.monotonic()<deadline:
                try: state=Path(f'/proc/{pid}/stat').read_text().rsplit(') ',1)[1].split()[0]
                except FileNotFoundError: break
                if state=='Z': break
                time.sleep(.02)
            else: self.fail('owned picker survived its helper')
        finally:
            if process.poll() is None: process.kill(); process.wait()
            process.stdout.close(); process.stderr.close()
    def test_launcher_chooses_binary_and_python_fallback(self):
        folder=self.root/'launcher'; folder.mkdir(); shutil.copy(ROOT/'MacShell/niri-color.sh',folder/'niri-color.sh')
        (folder/'niri_tools.py').write_text('import sys; print("legacy",*sys.argv[1:])\n')
        binary=folder/'niri-color-rust'; binary.write_text('#!/bin/sh\nif [ "${1-}" = --protocol-version ]; then echo "macshell-niri-color 1"; else echo rust; fi\n'); binary.chmod(0o755)
        def launch():return subprocess.run(['sh',str(folder/'niri-color.sh')],env=self.env,capture_output=True,text=True,timeout=5,check=True).stdout.strip()
        self.assertEqual(launch(),'rust'); binary.write_text('#!/bin/sh\necho wrong\n'); self.assertEqual(launch(),'legacy color')
        binary.unlink(); self.assertEqual(launch(),'legacy color')
    @unittest.skipUnless(shutil.which(quickshell()),'Quickshell is required')
    def test_actual_qml_action_launches_helper_from_path_with_spaces(self):
        folder=self.root/'shell with spaces'; folder.mkdir()
        shutil.copy(ROOT/'MacShell/niri-color.sh',folder/'niri-color.sh'); shutil.copy(BINARY,folder/'niri-color-rust')
        (folder/'niri_tools.py').write_text('raise SystemExit("unexpected Python fallback")\n')
        source=(ROOT/'MacShell/MacBar.qml').read_text()
        action=re.search(r'^    function pickColor\(\) \{[^\n]+\}',source,re.MULTILINE)
        self.assertIsNotNone(action)
        (folder/'shell.qml').write_text('import QtQuick\nimport Quickshell\nShellRoot {\n'+action.group(0)+'\nComponent.onCompleted: pickColor()\nTimer { interval: 1200; running: true; onTriggered: Qt.quit() }\n}\n')
        for name in ('runtime','config','cache'): (self.root/name).mkdir()
        (self.root/'runtime').chmod(0o700)
        env=dict(self.env,COLOR_REPLY='{"rgb":[1,0,0.5]}',XDG_RUNTIME_DIR=str(self.root/'runtime'),XDG_CONFIG_HOME=str(self.root/'config'),
                 XDG_CACHE_HOME=str(self.root/'cache'),QT_QPA_PLATFORM='offscreen',QT_QPA_PLATFORMTHEME='',QT_QUICK_BACKEND='software',
                 DBUS_SESSION_BUS_ADDRESS='unix:path='+str(self.root/'no-bus'))
        env.pop('DISPLAY',None); env.pop('WAYLAND_DISPLAY',None)
        result=subprocess.run([quickshell(),'-p',str(folder)],env=env,capture_output=True,text=True,timeout=8)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual([e['program'] for e in self.events()],['niri','wl-copy','notify-send'])
        self.assertEqual(self.events()[1]['args'],['#FF0080'])

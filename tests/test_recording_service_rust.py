"""Rust recorder against a fake compositor/recorder and temporary files."""
import json
import os
import queue
import shutil
import subprocess
import sys
import threading
import time
import unittest
from pathlib import Path

from test_dbus_protocol import Client
import test_recording_process as legacy
from scripts.install_niri import quickshell

BINARY = os.environ.get('MACSHELL_TEST_RECORDING_BINARY')
ROOT = Path(__file__).resolve().parents[1]


class NativeClient(Client):
    def __init__(self, environment):
        self.process = subprocess.Popen([BINARY], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        env=dict(os.environ, **environment), text=True)
        self.queue = queue.Queue()
        self.lines = []
        def read():
            for line in self.process.stdout:
                self.queue.put(json.loads(line))
        self.thread = threading.Thread(target=read, daemon=True)
        self.thread.start()
        self.sequence = 0


@unittest.skipUnless(BINARY and shutil.which('ffmpeg') and shutil.which('ffprobe'), 'Rust recorder and ffmpeg required')
class RecordingRustProcessTests(legacy.RecordingProcessTests):
    def setUp(self):
        super().setUp()
        self.client = NativeClient(self.env)
        self.addCleanup(self.client.close)
        self.client.wait(lambda m: m['type'] == 'ready')

    def test_rejects_unimplemented_audio(self):
        self.client.send('start', output='virtual', audio='invalid', region=False)
        self.assertIn('not supported', self.client.wait(lambda m: m['type'] == 'error')['error'])
        self.assertFalse((self.folder / 'Videos').exists())

    def test_launcher_falls_back_for_missing_or_incompatible_binary(self):
        directory = self.folder / 'launcher'
        directory.mkdir()
        launcher = directory / 'recording-service.sh'
        shutil.copy(ROOT / 'MacShell/recording-service.sh', launcher)
        (directory / 'recording_control.py').write_text('print("legacy")\n')
        def launch():
            return subprocess.run(['sh', str(launcher)], capture_output=True, text=True, check=True, timeout=5).stdout.strip()
        self.assertEqual(launch(), 'legacy')
        binary = directory / 'recording-service-rust'
        binary.write_text('#!/bin/sh\necho incompatible\n')
        binary.chmod(0o755)
        self.assertEqual(launch(), 'legacy')

    def test_area_selector_uses_fresh_monitor_and_preserves_geometry(self):
        slurp = self.bin / 'slurp'
        slurp.write_text('#!/bin/sh\nread -r hint\nprintf "%s\\n" "$hint" > "$REC_ARGS"\nprintf "%s\\n" "-1200,10 321x201"\n')
        slurp.chmod(0o755)
        self.client.send('select', output='virtual', region=False)
        self.client.wait(lambda m: m.get('state') == 'selecting')
        result = self.client.wait(lambda m: m.get('state') in ('choose', 'error'))
        self.assertEqual((result['state'], result['geometry']), ('choose', '-1200,10 321x201'))
        self.assertEqual((self.folder / 'args.json').read_text().strip(), '-1280,0 1280x720 virtual')

    def test_cancel_area_selector_never_applies_late_result(self):
        slurp = self.bin / 'slurp'
        slurp.write_text('#!' + sys.executable + '''
import os, pathlib, signal, sys, time
sys.stdin.readline()
pathlib.Path(os.environ['REC_ARGS']).write_text(str(os.getpid()))
signal.signal(signal.SIGINT, lambda *_: sys.exit(1))
while True: time.sleep(.02)
''')
        slurp.chmod(0o755)
        self.client.send('select', output='virtual', region=False)
        self.client.wait(lambda m: m.get('state') == 'selecting')
        deadline = time.monotonic() + 4
        while not (self.folder / 'args.json').exists() and time.monotonic() < deadline:
            time.sleep(.02)
        pid = int((self.folder / 'args.json').read_text())
        self.client.send('cancel')
        self.assertEqual(self.client.wait(lambda m: m.get('state') == 'choose')['geometry'], '')
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            try: os.kill(pid, 0)
            except ProcessLookupError: break
            time.sleep(.02)
        else: self.fail('selector process survived cancellation')

    def test_countdown_updates_before_start(self):
        self.client.send('start', output='virtual', audio='none', region=False)
        first = self.client.wait(lambda m: m.get('state') == 'countdown')
        second = self.client.wait(lambda m: m.get('state') == 'countdown' and m.get('countdown') == 2)
        self.assertEqual(first['countdown'], 3)
        self.assertEqual(second['countdown'], 2)
        self.client.send('cancel')
        self.client.wait(lambda m: m.get('state') == 'choose')

    def test_noisy_recorder_cannot_starve_ready_or_lose_first_frame(self):
        path = self.bin / 'wf-recorder'
        text = path.read_text().replace('while True: time.sleep(.1)', 'while True: print("synthetic log " * 200, flush=True)')
        path.write_text(text)
        self.client.send('start', output='virtual', audio='none', region=False)
        self.client.wait(lambda m: m.get('state') == 'recording', timeout=7)
        self.client.send('stop')
        result = self.client.wait(lambda m: m.get('state') in ('result', 'error'), timeout=7)
        self.assertEqual(result['state'], 'result', result)

    @unittest.skipUnless(shutil.which(quickshell()), 'Quickshell is required')
    def test_qml_controller_with_fake_recorder(self):
        graph = self.bin / 'pw-dump'
        graph.write_text('#!/bin/sh\nprintf "%s\\n" "[]"\n')
        graph.chmod(0o755)
        shell = self.folder / 'shell'
        shutil.copytree(ROOT / 'MacShell', shell)
        shutil.copy(ROOT / 'tests/recording-rust.qml', shell / 'shell.qml')
        shutil.copy(BINARY, shell / 'recording-service-rust')
        (shell / 'recording_control.py').write_text('raise SystemExit("unexpected Python fallback")\n')
        for name in ('runtime', 'config', 'cache'):
            (self.folder / name).mkdir()
        (self.folder / 'runtime').chmod(0o700)
        env = dict(os.environ, **self.env, XDG_RUNTIME_DIR=str(self.folder / 'runtime'),
            XDG_CONFIG_HOME=str(self.folder / 'config'), XDG_CACHE_HOME=str(self.folder / 'cache'),
            QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='', QT_QUICK_BACKEND='software',
            DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(self.folder / 'no-bus'))
        env.pop('DISPLAY', None)
        env.pop('WAYLAND_DISPLAY', None)
        result = subprocess.run([quickshell(), '-p', str(shell)], env=env, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('RECORDING_RUST_QML_PASS', result.stdout + result.stderr)

    def setup_fake_audio(self, target='mic'):
        source = self.folder / 'recorder.c'
        source.write_text(r'''
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <unistd.h>
__attribute__((used)) static const char marker[] = "libpipewire-0.3.so";
static volatile sig_atomic_t running = 1;
static void stop(int sig) { (void)sig; running = 0; }
int main(int argc, char **argv) {
  FILE *pid = fopen(getenv("REC_PID"), "w"); fprintf(pid, "%d", getpid()); fclose(pid);
  FILE *args = fopen(getenv("REC_ARGS"), "w");
  const char *path = NULL;
  for (int i=0; i<argc; ++i) { fprintf(args, "%s\n", argv[i]); if (i+1<argc && argv[i][0]=='-' && argv[i][1]=='f' && argv[i][2]==0) path=argv[i+1]; }
  fclose(args);
  if (!path) return 2;
  FILE *src = fopen(getenv("REC_FIXTURE"), "rb"), *dst = fopen(path, "wb");
  if (!src || !dst) return 3;
  char buffer[4096]; size_t n; while ((n=fread(buffer, 1, sizeof(buffer), src))) fwrite(buffer,1,n,dst);
  fclose(src); fclose(dst); signal(SIGINT, stop);
  puts("Writing block of size 100 with pts 0. TrackNumber 1, keyframe 1"); fflush(stdout);
  while (running) usleep(10000);
  return 0;
}
''')
        subprocess.run(['cc', '-O0', str(source), '-o', str(self.bin / 'wf-recorder')], check=True, capture_output=True, timeout=10)
        graph = self.bin / 'pw-dump'
        graph.write_text('#!' + sys.executable + r'''
import json, os, pathlib
pidfile = pathlib.Path(os.environ['REC_PID'])
mixdir = pathlib.Path(os.environ['REC_MIX_DIR'])
rows = [
 {'id':10,'type':'PipeWire:Interface:Node','info':{'props':{'node.name':'mic','media.class':'Audio/Source'}}},
 {'id':13,'type':'PipeWire:Interface:Node','info':{'props':{'node.name':'other','media.class':'Audio/Source'}}},
 {'id':14,'type':'PipeWire:Interface:Node','info':{'props':{'node.name':'speakers','media.class':'Audio/Sink'}}},
]
basefile = mixdir / 'base.json'
if basefile.exists():
 base = json.loads(basefile.read_text())
 rows += [
  {'id':20,'type':'PipeWire:Interface:Node','info':{'props':{'node.name':base['sink'],'media.class':'Audio/Sink'}}},
  {'id':21,'type':'PipeWire:Interface:Node','info':{'props':{'node.name':base['source'],'media.class':'Audio/Source'}}},
 ]
 for role, sourceid, capid, playid, linkid in [('system',14,22,23,30),('mic',10,24,25,32)]:
  file = mixdir / (role + '.json')
  if file.exists():
   route = json.loads(file.read_text())
   rows += [
    {'id':capid,'type':'PipeWire:Interface:Node','info':{'props':{'node.name':route['capture']}}},
    {'id':playid,'type':'PipeWire:Interface:Node','info':{'props':{'node.name':route['playback']}}},
    {'id':linkid,'type':'PipeWire:Interface:Link','info':{'output-node-id':sourceid,'input-node-id':capid,'state':'active'}},
    {'id':linkid+1,'type':'PipeWire:Interface:Link','info':{'output-node-id':playid,'input-node-id':20,'state':'active'}},
   ]
if pidfile.exists():
 pid = pidfile.read_text()
 rows += [
  {'id':11,'type':'PipeWire:Interface:Node','info':{'props':{'node.name':'wf-recorder','application.process.id':pid}}},
  {'id':12,'type':'PipeWire:Interface:Link','info':{'output-node-id':13 if pathlib.Path(os.environ['REC_WRONG']).exists() else 21 if basefile.exists() else 14 if os.environ['REC_TARGET']=='speakers' else 10,'input-node-id':11,'state':'active'}}
 ]
print(json.dumps(rows))
''')
        graph.chmod(0o755)
        probe = self.bin / 'ffprobe'
        probe.write_text('#!/bin/sh\nprintf "%s\\n" \'{"format":{"duration":"1"},"streams":[{"codec_type":"video"},{"codec_type":"audio"}]}\'\n')
        probe.chmod(0o755)
        # The already-running Rust helper inherited the old environment, so
        # restart it with paths for the entirely synthetic processes.
        self.env['REC_PID'] = str(self.folder / 'pid')
        self.env['REC_WRONG'] = str(self.folder / 'wrong')
        self.env['REC_TARGET'] = target
        mixdir = self.folder / 'mix'
        mixdir.mkdir()
        self.env['REC_MIX_DIR'] = str(mixdir)
        loopback = self.bin / 'pw-loopback'
        loopback.write_text('#!' + sys.executable + r'''
import json, os, pathlib, signal, sys, time
args = sys.argv
name = args[args.index('-n')+1]
capture = json.loads(args[args.index('-i')+1])['node.name']
playback = json.loads(args[args.index('-o')+1])['node.name']
directory = pathlib.Path(os.environ['REC_MIX_DIR'])
if '-C' not in args:
 role = 'base'; data = {'sink':capture,'source':playback,'pid':os.getpid()}
else:
 role = 'system' if name.endswith('_system') else 'mic'
 data = {'capture':capture,'playback':playback,'pid':os.getpid()}
tmp = directory / (role + '.tmp')
tmp.write_text(json.dumps(data))
tmp.replace(directory / (role + '.json'))
signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
while True: time.sleep(.05)
''')
        loopback.chmod(0o755)
        self.client = NativeClient(self.env)
        self.addCleanup(self.client.close)
        self.client.wait(lambda m: m['type'] == 'ready')

    @unittest.skipUnless(shutil.which('cc'), 'C compiler required for synthetic ELF recorder')
    def test_audio_requires_and_rechecks_the_selected_pipewire_link(self):
        self.setup_fake_audio()
        self.client.send('start', output='virtual', audio='mic', microphone='mic', region=False)
        self.client.wait(lambda m: m.get('state') == 'recording')
        args = (self.folder / 'args.json').read_text()
        self.assertIn('--audio-backend=pipewire', args)
        self.assertIn('--audio=mic', args)
        (self.folder / 'wrong').touch()
        result = self.client.wait(lambda m: m.get('state') == 'error', timeout=7)
        self.assertIn('audio link', result['error'].lower())
        self.assertTrue(os.path.isfile(result['file']))

    @unittest.skipUnless(shutil.which('cc'), 'C compiler required for synthetic ELF recorder')
    def test_mixed_audio_waits_for_both_routes_and_cleans_owned_processes(self):
        self.setup_fake_audio()
        self.client.send('start', output='virtual', audio='both', microphone='mic', sink='speakers', region=False)
        self.client.wait(lambda m: m.get('state') == 'mixing')
        self.client.wait(lambda m: m.get('state') == 'recording', timeout=10)
        mix = self.folder / 'mix'
        pids = [json.loads((mix / (name + '.json')).read_text())['pid'] for name in ('base', 'system', 'mic')]
        self.client.send('stop')
        result = self.client.wait(lambda m: m.get('state') in ('result', 'error'))
        self.assertEqual(result['state'], 'result', result)
        for pid in pids:
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)

    @unittest.skipUnless(shutil.which('cc'), 'C compiler required for synthetic ELF recorder')
    def test_system_audio_uses_selected_sink_and_saves_valid_result(self):
        self.setup_fake_audio('speakers')
        self.client.send('start', output='virtual', audio='system', sink='speakers', region=False)
        self.client.wait(lambda m: m.get('state') == 'recording', timeout=10)
        args = (self.folder / 'args.json').read_text()
        self.assertIn('--audio=speakers', args)
        self.client.send('stop')
        result = self.client.wait(lambda m: m.get('state') in ('result', 'error'))
        self.assertEqual(result['state'], 'result', result)

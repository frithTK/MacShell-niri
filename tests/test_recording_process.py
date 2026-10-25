"""Recorder orchestration with fake niri/wf-recorder and real ffprobe validation."""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from test_dbus_protocol import Client


@unittest.skipUnless(shutil.which('ffmpeg') and shutil.which('ffprobe'), 'ffmpeg and ffprobe are required')
class RecordingProcessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.bin = self.folder / 'bin'; self.bin.mkdir()
        self.server = socket.socket(socket.AF_UNIX)
        self.server.bind(str(self.folder / 'niri.sock')); self.server.listen(); self.server.settimeout(.2)
        self.running = True
        self.queries = 0
        def serve():
            while self.running:
                try: connection, _ = self.server.accept()
                except socket.timeout: continue
                except OSError: return
                with connection:
                    connection.recv(65536)
                    self.queries += 1
                    connection.sendall(json.dumps({'Ok': {'Outputs': {'virtual': {'logical': {'x': -1280, 'y': 0, 'width': 1280, 'height': 720, 'scale': 1.5}, 'current_mode': 0, 'modes': [{'width': 1920, 'height': 1080}]}}}}).encode() + b'\n')
        self.thread = threading.Thread(target=serve, daemon=True); self.thread.start()
        self.addCleanup(self.stop_server)
        fixture = self.folder / 'fixture.mkv'
        subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'color=c=blue:s=320x180:r=10', '-t', '0.5', '-c:v', 'libx264', str(fixture)], check=True, capture_output=True, timeout=10)
        script = '#!' + sys.executable + '''
import json, os, pathlib, shutil, signal, sys, time
pathlib.Path(os.environ['REC_ARGS']).write_text(json.dumps(sys.argv))
signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
shutil.copyfile(os.environ['REC_FIXTURE'], sys.argv[sys.argv.index('-f')+1])
print('Writing block of size 100 with pts 0. TrackNumber 1, keyframe 1', flush=True)
while True: time.sleep(.1)
'''
        (self.bin / 'wf-recorder').write_text(script); (self.bin / 'wf-recorder').chmod(0o755)
        self.env = {'HOME': self.temp.name, 'NIRI_SOCKET': str(self.folder / 'niri.sock'), 'PATH': str(self.bin) + ':' + os.environ['PATH'], 'REC_ARGS': str(self.folder / 'args.json'), 'REC_FIXTURE': str(fixture)}
        self.client = Client('recording_control.py', environment=self.env)
        self.addCleanup(self.client.close)
        self.client.wait(lambda m: m['type'] == 'ready')

    def stop_server(self):
        self.running = False
        self.thread.join(timeout=2); self.server.close()

    def test_recording_uses_fresh_logical_geometry_and_validates_the_container(self):
        self.client.send('start', output='virtual', audio='none', region=True, geometry='-1200,10 321x201')
        self.client.wait(lambda m: m.get('state') == 'recording')
        args = json.loads((self.folder / 'args.json').read_text())
        self.assertEqual(args[args.index('-g')+1], '-1200,10 321x201')
        self.assertIn('--no-damage', args)
        self.assertGreaterEqual(self.queries, 3)
        self.client.send('stop')
        state = self.client.wait(lambda m: m.get('state') in ('result', 'error'))
        self.assertEqual(state['state'], 'result', state)
        self.assertTrue(Path(state['file']).is_relative_to(self.folder / 'Videos'))
        self.assertEqual(Path(state['file']).suffix, '.mkv')
        self.assertEqual(len(list((self.folder / 'Videos').glob('*.mkv'))), 1)

    def test_buffered_video_does_not_need_file_bytes_before_recording(self):
        path = self.bin / 'wf-recorder'
        text = path.read_text().replace("shutil.copyfile(os.environ['REC_FIXTURE'], sys.argv[sys.argv.index('-f')+1])", '')
        text = text.replace("signal.signal(signal.SIGINT, lambda *_: sys.exit(0))", "def finish(*_):\n    shutil.copyfile(os.environ['REC_FIXTURE'], sys.argv[sys.argv.index('-f')+1])\n    sys.exit(0)\nsignal.signal(signal.SIGINT, finish)")
        path.write_text(text)
        self.client.send('start', output='virtual', audio='none', region=False)
        state = self.client.wait(lambda m: m.get('state') == 'recording')
        self.assertEqual(Path(state['file']).stat().st_size, 0)
        self.client.send('stop')
        result = self.client.wait(lambda m: m.get('state') in ('result', 'error'))
        self.assertEqual(result['state'], 'result', result)

    def test_cancel_countdown_never_spawns_a_recorder(self):
        self.client.send('start', output='virtual', audio='none', region=False)
        self.client.wait(lambda m: m.get('state') == 'countdown')
        self.client.send('cancel')
        self.client.wait(lambda m: m.get('state') == 'choose')
        self.assertFalse((self.folder / 'args.json').exists())
        self.assertFalse((self.folder / 'Videos').exists())

    def test_invalid_region_does_not_fall_back_to_the_whole_monitor(self):
        self.client.send('start', output='virtual', audio='none', region=True, geometry='bad')
        error = self.client.wait(lambda m: m.get('type') == 'error')
        self.assertIn('Invalid selection', error['error'])
        self.assertFalse((self.folder / 'args.json').exists())

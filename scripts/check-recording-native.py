#!/usr/bin/env python3
"""Record only an owned opaque Wayland surface and private virtual audio.

Needs niri, Quickshell, wf-recorder, PipeWire and its session manager; Pulse
builds also need pipewire-pulse/pactl. Does not change default audio devices.
All media and virtual nodes are temporary. Run deliberately in a live session.
"""
import argparse
import json
import os
from pathlib import Path
import queue
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid

project = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(project))
sys.path.insert(0, str(project / 'MacShell'))
from scripts.install_niri import quickshell
import recording_control as rec


def stop(child):
    if child and child.poll() is None:
        child.send_signal(signal.SIGINT)
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()


class Client:
    def __init__(self, service, home):
        self.messages = queue.Queue()
        self.process = subprocess.Popen([sys.executable, '-u', str(service)], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=dict(os.environ, HOME=str(home)))
        def read():
            for line in self.process.stdout:
                self.messages.put(json.loads(line))
        self.reader = threading.Thread(target=read, daemon=True)
        self.reader.start()

    def send(self, action, **data):
        self.process.stdin.write(json.dumps(dict(action=action, generation=1, data=data)) + '\n')
        self.process.stdin.flush()

    def wait(self, predicate, timeout=20):
        deadline, recent = time.monotonic() + timeout, []
        while time.monotonic() < deadline:
            try:
                message = self.messages.get(timeout=.2)
            except queue.Empty:
                if self.process.poll() is not None:
                    raise RuntimeError('Recorder service exited')
                continue
            recent.append(message)
            if predicate(message):
                return message
        raise RuntimeError('Recorder state timed out: ' + repr(recent[-4:]))

    def close(self):
        self.process.stdin.close()
        stop(self.process)
        self.reader.join(timeout=2)
        errors = self.process.stderr.read()
        self.process.stdout.close()
        self.process.stderr.close()
        assert not errors, errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--installed', action='store_true')
    parser.add_argument('--modes', nargs='+', choices=('none', 'system', 'mic', 'both'), default=['none', 'system', 'mic', 'both'])
    args = parser.parse_args()
    service = (Path.home() / '.config/quickshell/MacShell-niri' if args.installed else project / 'MacShell') / 'recording_control.py'
    with tempfile.TemporaryDirectory(prefix='macshell-recording-native-') as directory:
        root = Path(directory)
        name = 'macshell_probe_' + uuid.uuid4().hex
        props = {'node.virtual': True, 'node.autoconnect': False, 'node.dont-reconnect': True, 'priority.session': 0}
        mixer = panel = client = None
        try:
            mixer = subprocess.Popen(['pw-loopback', '-n', name, '-c', '2', '-i', json.dumps(dict(props, **{'node.name': name + '_sink', 'media.class': 'Audio/Sink'})),
                '-o', json.dumps(dict(props, **{'node.name': name + '_source', 'media.class': 'Audio/Source'}))], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if name + '_sink' in [node['name'] for node in rec.audio_nodes(rec.pipewire())['sinks']]:
                    break
                time.sleep(.1)
            else:
                raise RuntimeError('Private virtual audio did not appear')
            output = rec.outputs()[0]
            assert output['logical']['width'] >= 440 and output['logical']['height'] >= 320
            (root / 'shell.qml').write_text('''import QtQuick
import Quickshell
import Quickshell.Wayland
ShellRoot {
    PanelWindow {
        screen: Quickshell.screens.find(s => s.name === ''' + json.dumps(output['name']) + ''')
        anchors { top: true; left: true }
        margins { top: 120; left: 100 }
        implicitWidth: 320; implicitHeight: 180; exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        mask: Region {}
        color: "#123456"
        Rectangle { width: 40; height: 40; x: 50; y: 50; color: "#ffbb33" }
    }
}
''')
            with (root / 'panel.log').open('w') as log:
                panel = subprocess.Popen([quickshell(), '-p', str(root)], stdout=log, stderr=log)
            time.sleep(1)
            assert panel.poll() is None, (root / 'panel.log').read_text()
            rect = output['logical']
            geometry = f'{rect["x"] + 100},{rect["y"] + 120} 320x180'
            client = Client(service, root)
            client.wait(lambda message: message.get('type') == 'ready')
            for mode in args.modes:
                client.send('start', output=output['name'], audio=mode, region=True, geometry=geometry,
                    sink=name + '_sink', microphone=name + '_source')
                state = client.wait(lambda message: message.get('state') in ('recording', 'error') or message.get('type') == 'error')
                assert state.get('state') == 'recording', state
                initial_bytes = Path(state['file']).stat().st_size
                # Cross the former ten-second timeout on a static small image.
                for _ in range(12):
                    time.sleep(1)
                    client.send('status')
                    state = client.wait(lambda message: message.get('type') == 'state')
                    assert state['state'] == 'recording', state
                client.send('stop')
                state = client.wait(lambda message: message.get('state') in ('result', 'error'))
                assert state['state'] == 'result', state
                media = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-count_packets', '-show_entries',
                    'format=duration:stream=codec_type,nb_read_packets', '-of', 'json', state['file']], text=True, timeout=8))
                streams = {stream['codec_type']: int(stream.get('nb_read_packets', 0)) for stream in media['streams']}
                assert streams.get('video', 0) > 600, media
                assert mode == 'none' or streams.get('audio', 0) > 0, media
                print(json.dumps(dict(mode=mode, initial_file_bytes=initial_bytes, packets=streams, duration=media['format']['duration'])), flush=True)
            if args.modes != ['none']:
                client.send('start', output=output['name'], audio='system', region=True, geometry=geometry, sink=name + '_sink')
                state = client.wait(lambda message: message.get('state') in ('recording', 'error') or message.get('type') == 'error')
                assert state.get('state') == 'recording', state
                stop(mixer)
                state = client.wait(lambda message: message.get('state') == 'error')
                assert 'audio' in state['error'].lower(), state
                print('Owned audio target removal stops only the owned recording.', flush=True)
            print('MACSHELL_RECORDING_NATIVE_PASS', flush=True)
        finally:
            try:
                if client:
                    client.close()
            finally:
                stop(panel)
                stop(mixer)


if __name__ == '__main__':
    main()

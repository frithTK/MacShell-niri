#!/usr/bin/env python3
"""Exercise native window capture in disposable nested niri/PipeWire only."""
import json
import io
import os
from pathlib import Path
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from urllib.parse import unquote, urlparse

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts.install_niri import quickshell

TITLE = 'MacShell isolated capture fixture'


def stop(process):
    if process is None:
        return
    if process.poll() is None:
        process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def child(root, binary, recorder_binary, audio_test, parent_socket, parent_display):
    root = Path(root)
    nested_socket = os.environ.get('NIRI_SOCKET', '')
    display = os.environ.get('WAYLAND_DISPLAY', '')
    if not nested_socket or nested_socket == parent_socket or not display or display == parent_display:
        raise RuntimeError('Refusing a non-isolated compositor')
    if Path(os.environ.get('XDG_RUNTIME_DIR', '')).resolve() != (root / 'runtime').resolve():
        raise RuntimeError('Unexpected nested runtime directory')
    if Path(os.environ.get('PIPEWIRE_RUNTIME_DIR', '')).resolve() != (root / 'runtime').resolve():
        raise RuntimeError('Unexpected PipeWire runtime directory')
    display_path = Path(display) if os.path.isabs(display) else root / 'runtime' / display
    if display_path.resolve() == Path(parent_display).resolve() or not display_path.resolve().is_relative_to((root / 'runtime').resolve()):
        raise RuntimeError('Refusing a non-isolated Wayland display')
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.connect(nested_socket)
        pid, uid, _ = struct.unpack('3i', conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
    token = ('MACSHELL_NESTED_TEST_TOKEN=' + os.environ['MACSHELL_NESTED_TEST_TOKEN']).encode()
    if uid != os.getuid() or token not in Path('/proc', str(pid), 'environ').read_bytes().split(b'\0'):
        raise RuntimeError('Nested compositor does not own its socket')

    shell = root / 'shell'
    shell.mkdir()
    (shell / 'shell.qml').write_text('''import QtQuick
import Quickshell
ShellRoot {
    Window {
        visible: true; width: 320; height: 240; title: "MacShell isolated capture fixture"
        Rectangle { anchors.fill: parent; color: "#1fd24a" }
    }
}
''')
    env = dict(os.environ, QT_QPA_PLATFORM='wayland', QT_QPA_PLATFORMTHEME='', QT_QUICK_BACKEND='software')
    window = subprocess.Popen([quickshell(), '-p', str(shell)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    capture = None
    try:
        deadline = time.monotonic() + 15
        window_id = None
        while time.monotonic() < deadline and window.poll() is None:
            result = subprocess.run(['niri', 'msg', '-j', 'windows'], env=env, capture_output=True, text=True, timeout=3)
            if result.returncode == 0:
                windows = json.loads(result.stdout)
                matches = [item for item in windows if item.get('title') == TITLE and item.get('pid') == window.pid]
                if len(matches) == 1:
                    window_id = matches[0]['id']
                    break
            time.sleep(.1)
        if window_id is None:
            raise RuntimeError('The synthetic nested window did not appear')
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            owner = subprocess.run(['gdbus', 'call', '--session', '--dest', 'org.freedesktop.DBus',
                '--object-path', '/org/freedesktop/DBus', '--method', 'org.freedesktop.DBus.GetNameOwner',
                'org.gnome.Mutter.ScreenCast'], env=env, capture_output=True, text=True, timeout=3)
            if owner.returncode == 0:
                break
            time.sleep(.1)
        else:
            raise RuntimeError('Nested niri did not expose ScreenCast on its private session bus')
        capture_env = dict(env, GST_DEBUG='2', GST_DEBUG_NO_COLOR='1', GST_DEBUG_FILE=str(root / 'capture-gst.log'))
        capture = subprocess.Popen([binary], env=capture_env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        received = []
        def read():
            for line in capture.stdout:
                received.append(json.loads(line))
        reader = threading.Thread(target=read, daemon=True)
        reader.start()
        deadline = time.monotonic() + 15
        frame = None
        while time.monotonic() < deadline and capture.poll() is None:
            capture.stdin.write(json.dumps({'id': window_id}) + '\n')
            capture.stdin.flush()
            for event in received:
                if event.get('id') == window_id and event.get('error'):
                    raise RuntimeError('Capture error: ' + event['error'])
                if event.get('id') == window_id and event.get('url'):
                    frame = event
                    break
            if frame:
                break
            time.sleep(.15)
        if not frame:
            diagnostic = (root / 'capture-gst.log').read_text()[-5000:] if (root / 'capture-gst.log').exists() else ''
            capture.stdin.close(); capture.wait(timeout=8); reader.join(timeout=2)
            diagnostic += capture.stderr.read()[-5000:]
            raise RuntimeError('No frame from the synthetic nested window: ' + diagnostic)
        path = Path(unquote(urlparse(frame['url']).path))
        if not path.is_relative_to(root / 'runtime') or not path.read_bytes().startswith(b'\x89PNG\r\n\x1a\n'):
            raise RuntimeError('Capture did not create a private PNG in the nested runtime')
        from PIL import Image
        with Image.open(path) as image:
            red, green, blue = image.convert('RGB').getpixel((image.width // 2, image.height // 2))
        if not (red < 80 and green > 150 and blue < 120):
            raise RuntimeError('Captured frame does not match the synthetic window')
        capture.stdin.close()
        capture.wait(timeout=8)
        reader.join(timeout=2)
        if path.exists():
            raise RuntimeError('Preview frame was not removed after the worker exited')
        if recorder_binary:
            record_synthetic(root, recorder_binary, env)
            if audio_test == '1':
                for mode in ('mic', 'system', 'both'):
                    record_synthetic(root, recorder_binary, env, mode)
        (root / 'result').write_text(json.dumps({'ok': True, 'width': frame['width'], 'height': frame['height'], 'recorded': bool(recorder_binary), 'audio': audio_test == '1'}))
    finally:
        if capture:
            stop(capture)
            if capture.stdin and not capture.stdin.closed: capture.stdin.close()
            if capture.stdout: capture.stdout.close()
            if capture.stderr: capture.stderr.close()
        stop(window)
        if window.stderr: window.stderr.close()


def record_synthetic(root, binary, env, mode='none'):
    raw = subprocess.run(['niri', 'msg', '-j', 'outputs'], env=env, capture_output=True, text=True, timeout=4, check=True)
    outputs = json.loads(raw.stdout)
    active = [(name, value) for name, value in outputs.items() if value.get('logical') and value.get('current_mode') is not None]
    if len(active) != 1:
        raise RuntimeError('Nested compositor does not have exactly one test output')
    name, data = active[0]
    logical = data['logical']
    geometry = f'{logical["x"]},{logical["y"]} {logical["width"]}x{logical["height"]}'
    process = subprocess.Popen([binary], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    events = []
    def read():
        for line in process.stdout: events.append(json.loads(line))
    reader = threading.Thread(target=read, daemon=True); reader.start()
    graph = []
    next_graph = 0
    def send(action, data=None):
        process.stdin.write(json.dumps({'id': 1, 'generation': 1, 'action': action, 'data': data or {}}) + '\n')
        process.stdin.flush()
    try:
        send('start', {'output': name, 'audio': mode, 'region': True, 'geometry': geometry,
                       'microphone': 'macshell-test-microphone', 'sink': 'macshell-test-speakers'})
        deadline = time.monotonic() + 18
        while time.monotonic() < deadline and process.poll() is None:
            if mode != 'none' and time.monotonic() >= next_graph and any(v.get('state') == 'starting' for v in events):
                next_graph = time.monotonic() + 1
                dump = subprocess.run(['pw-dump'], env=env, capture_output=True, text=True, timeout=3)
                if dump.returncode == 0:
                    current = []
                    for obj in json.loads(dump.stdout):
                        props = obj.get('info', {}).get('props', {})
                        if obj.get('type', '').endswith(':Link'):
                            info = obj.get('info', {})
                            current.append({'id': obj['id'], 'output': info.get('output-node-id'), 'input': info.get('input-node-id'), 'state': info.get('state')})
                        elif props.get('node.name') or props.get('application.process.id'):
                            current.append({'id':obj['id'], 'name':props.get('node.name'), 'pid':props.get('application.process.id'), 'client':props.get('client.id'), 'class':props.get('media.class')})
                    for item in current:
                        if item not in graph: graph.append(item)
            if any(v.get('type') == 'error' or v.get('state') == 'error' for v in events):
                raise RuntimeError('Nested recording ' + mode + ' failed: ' + repr(events[-3:]) + ' graph=' + repr(graph))
            if any(v.get('state') == 'recording' for v in events): break
            time.sleep(.1)
        else:
            raise RuntimeError('Nested recording ' + mode + ' did not start: ' + repr(events[-3:]))
        time.sleep(.8)
        send('stop')
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline and process.poll() is None:
            result = next((v for v in events if v.get('state') in ('result', 'error')), None)
            if result: break
            time.sleep(.1)
        else:
            raise RuntimeError('Nested recording did not finish')
        if result['state'] != 'result':
            process.stdin.close()
            process.wait(timeout=6)
            raw_log = process.stderr.read()
            diagnostic = raw_log[:10000]
            raise RuntimeError('Nested recording ' + mode + ' failed: ' + repr(result) + ' graph=' + repr(graph) + ' log=' + diagnostic)
        path = Path(result['file'])
        if not path.is_relative_to(root / 'Videos') or not path.is_file(): raise RuntimeError('Recording escaped the nested test directory')
        image = subprocess.run(['ffmpeg', '-v', 'error', '-i', str(path), '-frames:v', '1', '-f', 'image2pipe', '-vcodec', 'png', '-'],
                               env=env, capture_output=True, timeout=8, check=True).stdout
        from PIL import Image
        with Image.open(io.BytesIO(image)) as sample:
            sample = sample.convert('RGB')
            matches = sum(1 for y in range(0, sample.height, max(1, sample.height // 32))
                          for x in range(0, sample.width, max(1, sample.width // 32))
                          if (lambda rgb: rgb[0] < 80 and rgb[1] > 150 and rgb[2] < 120)(sample.getpixel((x, y))))
        if matches < 5: raise RuntimeError('Recorded video does not contain the synthetic green window')
        if mode != 'none':
            import math, struct
            pcm = subprocess.run(['ffmpeg', '-v', 'error', '-i', str(path), '-vn', '-ac', '1', '-ar', '8000', '-f', 's16le', '-'],
                                 env=env, capture_output=True, timeout=8, check=True).stdout
            samples = [value[0] for value in struct.iter_unpack('<h', pcm)]
            if len(samples) < 2000:
                raise RuntimeError('Recorded ' + mode + ' audio does not contain the synthetic signal')
            frequencies = ([440] if mode == 'mic' else [660] if mode == 'system' else [440, 660])
            for frequency in frequencies:
                real = sum(value * math.cos(2 * math.pi * frequency * index / 8000) for index, value in enumerate(samples))
                imag = sum(value * math.sin(2 * math.pi * frequency * index / 8000) for index, value in enumerate(samples))
                if math.hypot(real, imag) / len(samples) < 50:
                    raise RuntimeError(f'Recorded {mode} audio does not contain the expected {frequency} Hz signal')
    finally:
        if process.stdin and not process.stdin.closed: process.stdin.close()
        stop(process)
        reader.join(timeout=2)
        process.stdout.close(); process.stderr.close()


def main():
    if len(sys.argv) > 1 and sys.argv[1] == '--child':
        try:
            child(*sys.argv[2:])
        except Exception as error:
            (Path(sys.argv[2]) / 'result').write_text(json.dumps({'ok': False, 'error': str(error)}))
            raise
        return
    if len(sys.argv) not in (2, 3, 4) or (len(sys.argv) == 4 and sys.argv[3] != '--audio'):
        raise SystemExit('Usage: check-capture-nested.py /absolute/path/to/capture-binary [recorder-binary [--audio]]')
    binary = Path(sys.argv[1]).resolve()
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise RuntimeError('Capture binary is missing')
    recorder = str(Path(sys.argv[2]).resolve()) if len(sys.argv) >= 3 else ''
    audio_test = len(sys.argv) == 4
    if recorder and (not Path(recorder).is_file() or not os.access(recorder, os.X_OK)):
        raise RuntimeError('Recorder binary is missing')
    parent_runtime = os.environ.get('XDG_RUNTIME_DIR', '')
    display = os.environ.get('WAYLAND_DISPLAY', '')
    if not parent_runtime or not display:
        raise RuntimeError('A parent Wayland session is required')
    parent_display = str(Path(display) if os.path.isabs(display) else Path(parent_runtime) / display)
    parent_socket = os.environ.get('NIRI_SOCKET', '')
    with tempfile.TemporaryDirectory(prefix='macshell-capture-nested-') as temporary:
        root = Path(temporary)
        runtime = root / 'runtime'; runtime.mkdir(mode=0o700)
        config = root / 'bus.conf'
        config.write_text('<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">'
                          '<busconfig><type>session</type><listen>unix:tmpdir=' + str(root) + '</listen><auth>EXTERNAL</auth>'
                          '<policy context="default"><allow own="*"/><allow send_destination="*"/><allow receive_sender="*"/></policy></busconfig>')
        env = dict(os.environ, HOME=str(root), XDG_RUNTIME_DIR=str(runtime), PIPEWIRE_RUNTIME_DIR=str(runtime),
                   PIPEWIRE_REMOTE='pipewire-0', XDG_CONFIG_HOME=str(root / 'config'), XDG_STATE_HOME=str(root / 'state'),
                   XDG_CACHE_HOME=str(root / 'cache'), WAYLAND_DISPLAY=parent_display, MACSHELL_NESTED_TEST_TOKEN=uuid.uuid4().hex)
        for key in ('NIRI_SOCKET', 'PIPEWIRE_CONFIG_DIR', 'PIPEWIRE_CONFIG_NAME'):
            env.pop(key, None)
        dbus = subprocess.Popen(['dbus-daemon', '--config-file=' + str(config), '--nofork', '--print-address=1'],
                                env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        daemon = manager = compositor = pulse = sink = microphone = microphone_loop = system_audio = None
        try:
            env['DBUS_SESSION_BUS_ADDRESS'] = dbus.stdout.readline().strip()
            if not env['DBUS_SESSION_BUS_ADDRESS'].startswith('unix:path=' + str(root) + '/'):
                raise RuntimeError('Refusing a non-isolated D-Bus address')
            env['DBUS_SYSTEM_BUS_ADDRESS'] = env['DBUS_SESSION_BUS_ADDRESS']
            daemon = subprocess.Popen(['pipewire'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            deadline = time.monotonic() + 6
            while not (runtime / 'pipewire-0').exists() and daemon.poll() is None and time.monotonic() < deadline:
                time.sleep(.05)
            if not (runtime / 'pipewire-0').exists(): raise RuntimeError('Private PipeWire did not start')
            manager = subprocess.Popen(['wireplumber', '-p', 'policy'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if audio_test:
                env['PULSE_SERVER'] = 'unix:' + str(runtime / 'pulse/native')
                pulse = subprocess.Popen(['pipewire-pulse'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                sink = subprocess.Popen(['pw-loopback', '-n', 'macshell-test-system', '-c', '2',
                    '-i', json.dumps({'node.name':'macshell-test-speakers','media.class':'Audio/Sink','node.virtual':True,'node.autoconnect':False}),
                    '-o', json.dumps({'node.name':'macshell-test-system-source','media.class':'Audio/Source','node.virtual':True,'node.autoconnect':False})],
                    env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                microphone_loop = subprocess.Popen(['pw-loopback', '-n', 'macshell-test-microphone-loop', '-c', '2',
                    '-i', json.dumps({'node.name':'macshell-test-microphone-input','media.class':'Audio/Sink','node.virtual':True,'node.autoconnect':False}),
                    '-o', json.dumps({'node.name':'macshell-test-microphone','media.class':'Audio/Source','node.virtual':True,'node.autoconnect':False})],
                    env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    dump = subprocess.run(['pw-dump'], env=env, capture_output=True, text=True, timeout=3)
                    if dump.returncode == 0:
                        names = {v.get('info', {}).get('props', {}).get('node.name') for v in json.loads(dump.stdout)}
                        if {'macshell-test-microphone', 'macshell-test-speakers'} <= names and (runtime / 'pulse/native').exists(): break
                    time.sleep(.1)
                else:
                    raise RuntimeError('Synthetic audio devices did not start on private PipeWire')
                microphone = subprocess.Popen(['gst-launch-1.0', '-q', 'audiotestsrc', 'is-live=true', 'wave=sine', '!',
                    'audioconvert', '!', 'audioresample', '!', 'pulsesink', 'device=macshell-test-microphone-input'],
                    env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                system_audio = subprocess.Popen(['gst-launch-1.0', '-q', 'audiotestsrc', 'is-live=true', 'wave=sine', 'freq=660', '!',
                    'audioconvert', '!', 'audioresample', '!', 'pulsesink', 'device=macshell-test-speakers'],
                    env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                sample_file = root / 'microphone-test.wav'
                sample = subprocess.Popen(['pw-record', '--target', 'macshell-test-microphone', '--rate', '48000', '--channels', '2', str(sample_file)],
                                          env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                time.sleep(2)
                sample.terminate()
                _, sample_error = sample.communicate(timeout=5)
                import wave
                try:
                    with wave.open(str(sample_file), 'rb') as recording:
                        frames = recording.readframes(recording.getnframes())
                    if len(frames) < 8192 or not any(frames):
                        raise RuntimeError('Synthetic microphone produced no samples')
                except (OSError, wave.Error) as error:
                    raise RuntimeError('Synthetic microphone could not be recorded: ' + sample_error.decode(errors='replace')[-500:]) from error
            niri_config = root / 'niri.kdl'
            niri_config.write_text('hotkey-overlay { skip-at-startup; }\ndebug { dbus-interfaces-in-non-session-instances; }\n')
            with (root / 'niri.log').open('w') as log:
                compositor = subprocess.Popen(['niri', '-c', str(niri_config), '--', sys.executable, str(Path(__file__).resolve()), '--child',
                                               str(root), str(binary), recorder, '1' if audio_test else '0', parent_socket, parent_display], env=env, stdout=log, stderr=subprocess.STDOUT)
                deadline = time.monotonic() + (110 if audio_test else 40)
                result = root / 'result'
                while time.monotonic() < deadline and not result.exists() and compositor.poll() is None: time.sleep(.1)
                if not result.exists(): raise RuntimeError('Nested capture timed out: ' + (root / 'niri.log').read_text()[-3000:])
                report = json.loads(result.read_text())
                if not report.get('ok'): raise RuntimeError(report.get('error', 'Nested capture failed') + '\n' + (root / 'niri.log').read_text()[-3000:])
                print('NESTED_CAPTURE_PASS:', report['width'], 'x', report['height'], 'recorded=' + str(report['recorded']), 'audio=' + str(report['audio']))
        finally:
            for process in (compositor, microphone, system_audio, microphone_loop, sink, pulse, manager, daemon, dbus): stop(process)
            if dbus.stdout: dbus.stdout.close()
            if dbus.stderr: dbus.stderr.close()


if __name__ == '__main__':
    main()

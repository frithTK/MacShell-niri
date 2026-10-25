#!/usr/bin/env python3
"""Operation-owned recording, strict logical geometry and optional PipeWire mix."""
import json
import math
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import subprocess
import time
import uuid
from line_service import LineService, protect_child
from niri_ipc import request as niri_request


def outputs():
    reply = niri_request('Outputs')
    values = reply.get('Outputs', reply) if isinstance(reply, dict) else {}
    return [{'name': name, 'logical': value['logical'], 'mode': value['modes'][value['current_mode']],
             'transform': value.get('logical', {}).get('transform', 'Normal')}
            for name, value in values.items() if value.get('logical') and value.get('current_mode') is not None]


def geometry(text, output):
    match = re.fullmatch(r'(-?\d+),(-?\d+) (\d+)x(\d+)', text)
    if not match:
        raise ValueError('Invalid selection. Choose the area again.')
    x, y, width, height = map(int, match.groups())
    logical = output['logical']
    if width < 2 or height < 2 or x < logical['x'] or y < logical['y'] or x + width > logical['x'] + logical['width'] or y + height > logical['y'] + logical['height']:
        raise ValueError('The area must fit entirely inside the selected monitor.')
    # Geometry stays in global logical coordinates. wf-recorder applies scale
    # and transform. Its encoder filter pads odd pixel dimensions once.
    return f'{x},{y} {width}x{height}'


def audio_nodes(objects):
    result = {'microphones': [], 'sinks': []}
    for obj in objects:
        props = obj.get('info', {}).get('props', {})
        name, kind = props.get('node.name', ''), props.get('media.class', '')
        if not name or name.startswith('macshell_record_'):
            continue
        role = 'microphones' if kind == 'Audio/Source' else 'sinks' if kind == 'Audio/Sink' else None
        if role:
            result[role].append({'name': name, 'label': props.get('node.description', name), 'id': obj['id']})
    for value in result.values():
        value.sort(key=lambda n: (n['label'].casefold(), n['name']))
    return result


def audio_link_state(objects, pid, target, routes=None):
    """Return ready/waiting/wrong for THIS recorder's node and selected source."""
    by_id = {o['id']: o for o in objects}
    nodes = {o['id']: o.get('info', {}).get('props', {}) for o in objects if o.get('type', '').endswith(':Node')}
    target_ids = {i for i, p in nodes.items() if p.get('node.name') == target}
    recorder_ids = set()
    for node, props in nodes.items():
        client = by_id.get(int(props.get('client.id', -1)), {}).get('info', {}).get('props', {})
        process = props.get('application.process.id', client.get('application.process.id', ''))
        if props.get('node.name') in ('wf-recorder', 'wf-recorder3') and str(process) == str(pid):
            recorder_ids.add(node)
    links = [o.get('info', {}) for o in objects if o.get('type', '').endswith(':Link')]
    attached = [link for link in links if link.get('input-node-id') in recorder_ids]
    if any(link.get('output-node-id') not in target_ids for link in attached):
        return 'wrong'
    if not attached or not all(link.get('state') == 'active' for link in attached):
        return 'waiting'
    for source, capture, playback, sink in routes or []:
        names = {p.get('node.name'): i for i, p in nodes.items()}
        for out, inp in [(source, capture), (playback, sink)]:
            if out not in names or inp not in names or not any(link.get('output-node-id') == names[out] and link.get('input-node-id') == names[inp] and link.get('state') == 'active' for link in links):
                return 'waiting'
    return 'ready'


def pipewire():
    result = subprocess.run(['pw-dump'], capture_output=True, timeout=3, check=True)
    return json.loads(result.stdout)


def recorder_audio_backend():
    # wf-recorder --help advertises both backends even when one was compiled
    # out. An unsupported --audio-backend silently creates no audio reader.
    # Inspect the linked library names of the selected Linux ELF executable;
    # unknown/static/wrapped builds need an explicit supported installation.
    program = shutil.which('wf-recorder')
    if program:
        with open(program, 'rb') as binary:
            data = binary.read(16 * 1024 * 1024)
        if data.startswith(b'\x7fELF'):
            if b'libpipewire-0.3.so' in data:
                return 'pipewire'
            if b'libpulse-simple.so' in data:
                return 'pulse'
    raise ValueError('Cannot identify an available wf-recorder audio backend. Install a build linked with PipeWire or PulseAudio, or choose No audio.')


def pulse_source(target, is_sink):
    if not shutil.which('pactl'):
        raise ValueError('This wf-recorder build needs pactl and pipewire-pulse to record audio.')
    result = subprocess.run(['pactl', '-f', 'json', 'list', 'sources'], capture_output=True, timeout=3, check=True)
    sources = json.loads(result.stdout)
    matches = [source['name'] for source in sources if source.get('name')
               and source.get('properties', {}).get('node.name') == target
               and bool(source.get('monitor_source')) == is_sink]
    if len(matches) != 1:
        raise ValueError('The selected audio device is not uniquely available through pipewire-pulse. Choose the device again.')
    return matches[0]


def valid_file(path, expect_audio):
    try:
        result = subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration:stream=codec_type', '-of', 'json', str(path)], capture_output=True, timeout=8, check=True)
        data = json.loads(result.stdout)
        types = [s['codec_type'] for s in data.get('streams', [])]
        return float(data.get('format', {}).get('duration', 0)) > 0 and 'video' in types and (not expect_audio or 'audio' in types)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        return False


class Recorder(LineService):
    def __init__(self):
        super().__init__()
        self.child = None
        self.routes = []
        self.selection = None
        self.state = 'choose'
        self.config = {}
        self.file = None
        self.error = ''
        self.when = 0
        self.started = 0
        self.stopping = 0
        self.log = ''
        self.countdown = -1
        self.progress = False
        self.audio_target = ''
        self.mix_token = ''
        self.mix_deadline = 0
        self.forced = False
        self.failure = ''
        self.last_validate = 0
        self.audio_routes = []
        self.audio_ready = False
        self.audio_backend = ''

    def wait_timeout(self):
        return .2 if self.child or self.selection or self.state in ('selecting', 'countdown', 'mixing', 'starting') else None

    def publish(self):
        self.emit(type='state', state=self.state, countdown=self.countdown, elapsed=max(0, int(time.monotonic() - self.started)) if self.started else 0,
                  file=str(self.file or ''), error=self.error, geometry=self.config.get('geometry', ''))

    def fail(self, error):
        if self.child:
            self.failure = error
            self.stop()
        else:
            self.cleanup_audio()
            self.state, self.error = 'error', error
            self.when = 0
            self.publish()

    def prepare(self):
        if not self.child and self.state in ('choose', 'result', 'error'):
            self.state, self.error, self.file = 'choose', '', None
            self.publish()
        monitors = outputs()  # Fresh IPC, never the event bridge's cached geometry.
        try:
            audio = audio_nodes(pipewire())
            audio_error = ''
        except (OSError, ValueError, subprocess.SubprocessError):
            audio, audio_error = {'microphones': [], 'sinks': []}, 'PipeWire audio is unavailable.'
        self.emit(type='choices', outputs=monitors, audio=audio, audioError=audio_error,
                  available=bool(shutil.which('wf-recorder')), mixAvailable=bool(shutil.which('pw-loopback')))

    def current_output(self):
        output = next((v for v in outputs() if v['name'] == self.config.get('output')), None)
        if not output:
            raise ValueError('The selected monitor is no longer available.')
        return output

    def validate(self):
        output = self.current_output()
        if self.config.get('region'):
            self.config['geometry'] = geometry(self.config.get('geometry', ''), output)
        mode = self.config.get('audio', 'none')
        if mode not in ('none', 'system', 'mic', 'both'):
            raise ValueError('Invalid audio mode.')
        if mode != 'none':
            choices = audio_nodes(pipewire())
            if mode in ('system', 'both') and self.config.get('sink') not in [n['name'] for n in choices['sinks']]:
                raise ValueError('The selected system audio device disappeared. Choose a device again.')
            if mode in ('mic', 'both') and self.config.get('microphone') not in [n['name'] for n in choices['microphones']]:
                raise ValueError('The selected microphone disappeared. Choose a microphone again.')
        return output

    def command(self, request):
        action, data = request['action'], request.get('data', {})
        if action == 'status':
            self.publish()
            return
        if action == 'prepare':
            self.prepare()
            return
        if action in ('cancel', 'stop'):
            if self.selection:
                self.selection.terminate()
            if self.child:
                self.stop()
            else:
                self.cleanup_audio()
                self.state, self.error, self.when = 'choose', '', 0
                self.publish()
            return
        if self.selection is not None:
            raise ValueError('Wait for the area selector to close, then try again.')
        if self.state not in ('choose', 'result', 'error'):
            raise ValueError('A recording operation is already in progress.')
        self.config = dict(data)
        self.error, self.failure, self.forced = '', '', False
        if action == 'select':
            self.current_output()
            if not shutil.which('slurp'):
                raise ValueError('Install slurp to select an area.')
            self.state, self.when = 'selecting', time.monotonic() + .4
        elif action == 'start':
            if not shutil.which('wf-recorder') or not shutil.which('ffprobe'):
                raise ValueError('Install wf-recorder and ffmpeg (ffprobe) to record.')
            self.validate()
            self.audio_backend = recorder_audio_backend() if self.config.get('audio', 'none') != 'none' else ''
            self.state, self.when, self.countdown = 'countdown', time.monotonic() + 3, 3
        else:
            raise ValueError('Unknown recording action.')
        self.publish()

    def route(self, args):
        env = dict(os.environ)
        child = subprocess.Popen(['pw-loopback'] + args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env, preexec_fn=protect_child)
        self.routes.append(child)

    def start_audio(self):
        mode = self.config.get('audio', 'none')
        self.audio_target = ''
        if mode == 'system':
            self.audio_target = self.config['sink']
        elif mode == 'mic':
            self.audio_target = self.config['microphone']
        elif mode == 'both':
            if not shutil.which('pw-loopback'):
                raise ValueError('Install pw-loopback to mix microphone and system audio.')
            self.mix_token = 'macshell_record_' + uuid.uuid4().hex
            sink, source = self.mix_token + '_sink', self.mix_token + '_source'
            props = {'node.virtual': True, 'node.autoconnect': False, 'node.dont-reconnect': True}
            self.route(['-n', self.mix_token, '-c', '2', '-i', json.dumps(dict(props, **{'node.name': sink, 'media.class': 'Audio/Sink'})), '-o', json.dumps(dict(props, **{'node.name': source, 'media.class': 'Audio/Source'}))])
            self.audio_target = source
            self.mix_deadline = time.monotonic() + 5
            self.state = 'mixing'

    def start_recorder(self):
        self.validate()  # Monitor/audio may have vanished during the countdown.
        audio_source = self.audio_target
        if audio_source:
            nodes = [o.get('info', {}).get('props', {}) for o in pipewire()]
            selected = next((node for node in nodes if node.get('node.name') == audio_source), None)
            if not selected:
                raise ValueError('The selected audio source is no longer available.')
            if self.audio_backend == 'pulse':
                audio_source = pulse_source(audio_source, selected.get('media.class') == 'Audio/Sink')
        folder = Path.home() / 'Videos'
        folder.mkdir(parents=True, exist_ok=True)
        self.file = folder / ('Screen-Recording-' + time.strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:8] + '.mkv')
        # Reserve our unique path; no shell, no overwrite, no shared PID files.
        fd = os.open(self.file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(fd)
        args = ['wf-recorder', '-f', str(self.file), '-y', '-o', self.config['output'], '-r', '60', '--no-damage', '-c', 'libx264', '-p', 'preset=veryfast', '-p', 'crf=20', '-F', 'pad=ceil(iw/2)*2:ceil(ih/2)*2', '--log']
        if self.config.get('region'):
            args += ['-g', self.config['geometry']]
        if self.audio_target:
            args += ['--audio-backend=' + self.audio_backend, '--audio=' + audio_source]
        env = dict(os.environ)
        if self.audio_backend == 'pulse':
            for key in ('node.dont-reconnect', 'node.dont-fallback', 'node.dont-move'):
                env['PULSE_PROP_' + key] = 'true'
        self.child = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env, preexec_fn=protect_child)
        self.selector.register(self.child.stdout, selectors.EVENT_READ, self.read_log)
        self.state, self.started, self.progress, self.log = 'starting', time.monotonic(), False, ''
        self.audio_ready = not self.audio_target
        self.publish()

    def read_log(self, source):
        data = os.read(source.fileno(), 65536)
        if not data:
            return
        self.log = (self.log + data.decode('utf-8', 'replace'))[-16384:]
        # A filter/header is not a frame. Matroska can buffer the entire first
        # seconds of a small recording in memory, so file size is not readiness.
        if re.search(r'Writing block of size [1-9]\d* .*TrackNumber 1,|\bframe=\s*[1-9]\d*', self.log):
            self.progress = True
        if any(marker in self.log for marker in ('not found, using default', 'pipewire: core error', 'Failed to connect to PulseAudio', 'Failed to read from PulseAudio stream')):
            self.fail('The audio source was lost. Recording stopped to avoid capturing another device.')

    def stop(self):
        if self.child and self.state != 'stopping':
            self.child.send_signal(signal.SIGINT)
            self.state, self.stopping = 'stopping', time.monotonic()
            self.publish()

    def cleanup_audio(self):
        for child in reversed(self.routes):
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
        self.routes = []
        self.mix_token = ''
        self.audio_routes = []

    def tick(self):
        now = time.monotonic()
        try:
            if self.state == 'selecting' and self.when and now >= self.when:
                self.when = 0
                output = self.current_output()
                rect = output['logical']
                hint = f'{rect["x"]},{rect["y"]} {rect["width"]}x{rect["height"]} {output["name"]}\n'
                self.selection = subprocess.Popen(['slurp', '-f', '%x,%y %wx%h'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, preexec_fn=protect_child)
                self.selection.stdin.write(hint.encode())
                self.selection.stdin.close()
            if self.selection and self.selection.poll() is not None:
                selected = self.selection.stdout.read().decode().strip()
                code = self.selection.returncode
                self.selection.stdout.close()
                self.selection = None
                if self.state != 'selecting':
                    return  # Late completion after an explicit cancellation.
                if code != 0:
                    self.state = 'choose'
                else:
                    self.config['geometry'] = geometry(selected, self.current_output())
                    self.config['region'] = True
                    self.state = 'choose'
                self.publish()
            if self.state == 'countdown':
                seconds = max(0, math.ceil(self.when - now))
                if seconds != self.countdown:
                    self.countdown = seconds
                    self.publish()
                if now >= self.when:
                    self.state, self.when = 'starting', now + .4
                    self.publish()  # Frontend hides menus BEFORE a recorder exists.
            if self.state == 'starting' and self.child is None and self.when and now >= self.when:
                self.when = 0
                self.validate()
                self.start_audio()
                if self.state != 'mixing':
                    self.start_recorder()
            if self.state == 'mixing':
                if any(p.poll() is not None for p in self.routes):
                    raise ValueError('The PipeWire mixer could not start.')
                nodes = audio_nodes(pipewire())
                names = [o.get('info', {}).get('props', {}).get('node.name') for o in pipewire()]
                if self.mix_token + '_sink' in names and self.audio_target in names:
                    for role, target in [('system', self.config['sink']), ('mic', self.config['microphone'])]:
                        capture = {'node.dont-reconnect': True}
                        if role == 'system':
                            capture['stream.capture.sink'] = True
                        self.route(['-n', self.mix_token + '_' + role, '-C', target, '-P', self.mix_token + '_sink', '-i', json.dumps(dict(capture, **{'node.name': self.mix_token + '_' + role + '_capture'})), '-o', json.dumps({'node.dont-reconnect': True, 'node.name': self.mix_token + '_' + role + '_playback'})])
                        self.audio_routes.append((target, self.mix_token + '_' + role + '_capture', self.mix_token + '_' + role + '_playback', self.mix_token + '_sink'))
                    self.start_recorder()
                elif now > self.mix_deadline:
                    raise ValueError('The PipeWire mixer did not become ready.')
            if self.child:
                if self.child.poll() is not None:
                    code = self.child.returncode
                    self.selector.unregister(self.child.stdout)
                    self.child.stdout.close()
                    self.child = None
                    self.state = 'saving'
                    self.publish()
                    self.cleanup_audio()
                    valid = valid_file(self.file, self.config.get('audio', 'none') != 'none')
                    self.state = 'result' if valid and not self.forced and not self.failure and code in (0, -signal.SIGINT, 130) else 'error'
                    self.error = '' if self.state == 'result' else self.failure or 'Recording did not finish cleanly. A partial file was kept; check it before using it.'
                    self.publish()
                elif self.state == 'starting':
                    if self.audio_target:
                        audio_state = audio_link_state(pipewire(), self.child.pid, self.audio_target, self.audio_routes)
                        if audio_state == 'wrong':
                            self.fail('The recorder connected to an unexpected audio source.')
                            return
                        self.audio_ready = audio_state == 'ready'
                    if self.audio_ready and self.progress:
                        self.state = 'recording'
                        self.publish()
                    elif now - self.started > 10:
                        if not self.progress:
                            self.fail('No video frames arrived. Check recorder and screen capture support.')
                        else:
                            self.fail('Audio capture did not connect to the selected device. Check the recorder audio backend and PipeWire links.')
                elif self.state == 'recording':
                    if self.config.get('audio') != 'none' and any(p.poll() is not None for p in self.routes):
                        self.fail('The audio mixer stopped. A partial recording was kept.')
                    elif now - self.last_validate >= 1:
                        self.last_validate = now
                        self.validate()
                        if self.audio_target and audio_link_state(pipewire(), self.child.pid, self.audio_target, self.audio_routes) != 'ready':
                            self.fail('An audio link disappeared. Recording stopped to avoid capturing another device.')
                elif self.state == 'stopping' and now - self.stopping > 10:
                    self.forced = True
                    self.child.kill()
        except (OSError, ValueError, RuntimeError, KeyError, subprocess.SubprocessError) as error:
            self.fail(str(error))

    def close(self):
        if self.selection and self.selection.poll() is None:
            self.selection.terminate()
            self.selection.wait(timeout=3)
        if self.child and self.child.poll() is None:
            self.child.send_signal(signal.SIGINT)
            try:
                self.child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.child.kill()
                self.child.wait()
        self.cleanup_audio()


if __name__ == '__main__':
    Recorder().run()

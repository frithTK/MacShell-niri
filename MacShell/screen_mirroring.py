#!/usr/bin/env python3
"""AirPlay controls for owned Doubletake and UxPlay processes."""
from collections import deque
import ipaddress
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import socket
import subprocess
import tempfile
import time

from line_service import LineService, protect_child


# UxPlay otherwise chooses ephemeral ports, which cannot be allowed narrowly
# through a host firewall. -p reserves three consecutive TCP and UDP ports.
RECEIVER_PORT = 7100


def backend(name):
    runtime = Path(os.environ.get('XDG_DATA_HOME', Path.home() / '.local/share')) / 'macshell-niri/runtime/bin' / name
    if name == 'doubletake' and runtime.is_file() and os.access(runtime, os.X_OK):
        return str(runtime)
    installed = shutil.which(name)
    if installed:
        return installed
    return str(runtime) if runtime.is_file() and os.access(runtime, os.X_OK) else None


def devices_from_response(items):
    devices = {}
    for item in items[:100] if isinstance(items, list) else []:
        if not isinstance(item, dict):
            continue
        try:
            address = str(ipaddress.ip_address(item['ip']))
            port = int(item.get('port', 7000))
            if not 1 <= port <= 65535:
                continue
            key = address + '|' + str(port)
            devices[key] = dict(key=key, name=str(item.get('name') or address)[:120],
                                model=str(item.get('model') or '')[:100], address=address, port=port)
        except (KeyError, ValueError, TypeError):
            continue
    return sorted(devices.values(), key=lambda item: (item['name'].casefold(), item['key']))


class ScreenMirroring(LineService):
    def __init__(self):
        super().__init__()
        self.temporary = tempfile.TemporaryDirectory(prefix='macshell-airplay-')
        self.folder = Path(self.temporary.name)
        self.socket_path = str(self.folder / 'sender.sock')
        self.sender = None
        self.receiver = None
        self.sender_state = 'off'
        self.receiver_state = 'off'
        self.sender_error = ''
        self.receiver_error = ''
        self.receiver_name = 'MacShell'
        self.receiver_pin = ''
        self.receiver_client = ''
        self.devices = []
        self.streams = []
        self.watching = False
        self.scan_until = 0
        self.next_poll = 0
        self.rpc = None
        self.queue = deque()
        self.logs = {}
        self.started = {}
        self.last_publication = None
        self.credentials_to_hide = deque(maxlen=4)
        self.fps = 60
        self.volume_percent = 20

    def clean_error(self, error):
        message = str(error or '')[:400]
        for credential in self.credentials_to_hide:
            message = message.replace(credential, '[hidden]')
        return message[:240]

    def wait_timeout(self):
        return .15 if self.sender or self.receiver or self.rpc else None

    def publish(self):
        state = dict(type='state', senderAvailable=bool(backend('doubletake')),
                     receiverAvailable=bool(backend('uxplay')), senderState=self.sender_state,
                     receiverState=self.receiver_state, senderError=self.sender_error,
                     receiverError=self.receiver_error, receiverName=self.receiver_name,
                     receiverPin=self.receiver_pin, receiverClient=self.receiver_client,
                     devices=self.devices, streams=self.streams,
                     scanning=time.monotonic() < self.scan_until)
        if state != self.last_publication:
            self.last_publication = state
            self.emit(**state)

    def spawn(self, command, kind, env=None):
        child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, env=env, preexec_fn=protect_child)
        os.set_blocking(child.stdout.fileno(), False)
        self.logs[child.stdout] = [kind, b'']
        self.selector.register(child.stdout, selectors.EVENT_READ, self.read_log)
        self.started[kind] = time.monotonic()
        return child

    def doubletake_supports_volume(self, executable):
        try:
            result = subprocess.run([executable, '-help'], capture_output=True, text=True, timeout=3)
            return 'volume-percent' in result.stdout + result.stderr
        except (OSError, subprocess.SubprocessError):
            return False

    def stop_process(self, kind):
        child = getattr(self, kind)
        if child is None:
            return
        if child.poll() is None:
            child.send_signal(signal.SIGINT)
            try:
                child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=2)
        if child.stdout in self.logs:
            self.selector.unregister(child.stdout)
            self.logs.pop(child.stdout)
        child.stdout.close()
        setattr(self, kind, None)

    def start_sender(self):
        if self.sender:
            return
        executable = backend('doubletake')
        if not executable:
            self.sender_state = 'unavailable'
            self.sender_error = 'Install doubletake to mirror this screen to an AirPlay display.'
            return
        config = Path(os.environ.get('XDG_CONFIG_HOME', Path.home() / '.config')) / 'macshell-niri/airplay'
        config.mkdir(parents=True, exist_ok=True, mode=0o700)
        command = [executable, '-daemonize', '-socket', self.socket_path,
                   '-fps', str(self.fps), '-creds', str(config / 'credentials.json')]
        supports_volume = self.doubletake_supports_volume(executable)
        if self.volume_percent != 100 and not supports_volume:
            self.sender_state = 'error'
            self.sender_error = 'This Doubletake runtime cannot set the TV volume. Install the patched runtime with -volume-percent.'
            return
        if supports_volume:
            command += ['-volume-percent', str(self.volume_percent)]
        self.sender = self.spawn(command, 'sender')
        self.sender_state = 'starting'
        self.sender_error = ''
        self.next_poll = 0

    def stop_sender(self):
        self.end_rpc()
        self.queue.clear()
        self.stop_process('sender')
        self.streams = []
        self.scan_until = 0

    def start_receiver(self, name):
        if self.receiver:
            return
        executable = backend('uxplay')
        if not executable:
            self.receiver_state = 'unavailable'
            self.receiver_error = 'Install uxplay to receive an iPhone, iPad or Mac screen.'
            return
        name = str(name).strip()
        if not name or len(name.encode('utf-8')) > 60 or any(ord(c) < 32 for c in name):
            raise ValueError('Use an AirPlay name of 1–60 UTF-8 bytes without control characters.')
        # Ignore unrelated UxPlay defaults: this instance is owned by MacShell.
        rc = self.folder / 'uxplayrc'
        rc.touch(mode=0o600)
        self.receiver_name = name
        self.receiver_pin = self.receiver_client = self.receiver_error = ''
        env = dict(os.environ, UXPLAYRC=str(rc), LC_ALL='C')
        config = Path(os.environ.get('XDG_CONFIG_HOME', Path.home() / '.config')) / 'macshell-niri/airplay'
        config.mkdir(parents=True, exist_ok=True, mode=0o700)
        command = [executable, '-n', name, '-nh', '-pin', '-key', str(config / 'receiver.pem'),
                   '-p', str(RECEIVER_PORT), '-d', '1', '-vs', 'waylandsink', '-as', 'pipewiresink']
        if shutil.which('stdbuf'):
            command = [shutil.which('stdbuf'), '-oL', '-eL'] + command
        self.receiver = self.spawn(command, 'receiver', env)
        self.receiver_state = 'starting'

    def read_log(self, source):
        data = os.read(source.fileno(), 32768)
        if not data:
            self.selector.unregister(source)
            self.logs.pop(source, None)
            return
        kind, pending = self.logs[source]
        pending += data
        while b'\n' in pending:
            raw, pending = pending.split(b'\n', 1)
            if kind == 'receiver':
                self.receiver_line(raw.decode('utf-8', 'replace'))
        self.logs[source][1] = pending[-16384:]

    def receiver_line(self, line):
        # UxPlay may still publish mDNS after failing to open its listener.
        # A later advertisement must not turn a failed start into readiness.
        if self.receiver_state == 'error':
            return
        if 'register_dnssd: advertised AirPlay service' in line:
            self.receiver_state = 'waiting'
        pin = re.search(r'CLIENT MUST NOW ENTER PIN = "([0-9]{4})"', line)
        if pin:
            self.receiver_pin = pin[1]
        client = re.search(r'connection request from (.*?) \(', line)
        if client:
            self.receiver_client = client[1][:100]
        if 'Begin streaming to GStreamer video pipeline' in line or 'start audio connection, format' in line:
            self.receiver_state = 'streaming'
            self.receiver_pin = ''
        if re.search(r'video_reset: type\s*=\s*(RTP_Shutdown|HLS_Shutdown)|lost connection with client', line) or 'Open connections: 0' in line and self.receiver_state == 'streaming':
            self.receiver_state = 'waiting'
            self.receiver_pin = self.receiver_client = ''
        if re.search(r'Error (binding|initiali[sz]ing(?: IPv[46])?|listening to IPv[46]) socket', line, re.I):
            self.receiver_error = 'AirPlay ports 7100–7102 are already in use or unavailable. Stop another receiver and try again.'
            self.receiver_state = 'error'
        elif re.search(r'dnssd_register_.*failed|Could not initialize dnssd|Failed to initialize|GStreamer error|could not.*(display|sink)', line, re.I):
            self.receiver_error = 'AirPlay receiver could not start. Check the network, Wayland and GStreamer plug-ins.'
            self.receiver_state = 'error'
        self.publish()

    def enqueue(self, command, **data):
        if not self.sender:
            raise ValueError('Open Screen Mirroring and wait for AirPlay discovery first.')
        if len(self.queue) >= 8:
            raise ValueError('Wait for the current AirPlay operation.')
        self.queue.append(dict(cmd=command, **data))
        self.next_poll = 0

    def begin_rpc(self, request):
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            connection.settimeout(.2)
            connection.connect(self.socket_path)
            connection.sendall(json.dumps(request).encode() + b'\n')
            connection.setblocking(False)
            self.rpc = dict(socket=connection, request=request, buffer=b'', deadline=time.monotonic() + 3)
            self.selector.register(connection, selectors.EVENT_READ, self.read_rpc)
        except OSError:
            connection.close()
            raise

    def end_rpc(self):
        if self.rpc:
            self.selector.unregister(self.rpc['socket'])
            self.rpc['socket'].close()
            self.rpc = None

    def read_rpc(self, source):
        try:
            data = source.recv(65536)
            self.rpc['buffer'] += data
            if len(self.rpc['buffer']) > 1048576:
                raise ValueError('AirPlay sender response is too large.')
            if b'\n' not in self.rpc['buffer'] and data:
                return
            response = json.loads(self.rpc['buffer'])
            request = self.rpc['request']
            self.end_rpc()
            self.apply_response(request, response)
        except (OSError, ValueError, TypeError, KeyError):
            self.sender_failed('AirPlay sender returned an invalid response. Try searching again.')

    def apply_response(self, request, response):
        if not isinstance(response, dict):
            raise ValueError('Invalid AirPlay response')
        if not response.get('ok'):
            # Pairing secrets never enter status, settings, command lines or logs.
            self.sender_error = self.clean_error(response.get('error') or 'AirPlay operation failed.')
        if request['cmd'] == 'devices':
            self.devices = devices_from_response(response.get('devices', []))
        elif request['cmd'] == 'status':
            if any(item['cmd'] == 'connect' for item in self.queue):
                return  # A status started before the user action cannot undo its busy state.
            state = response.get('state', 'idle')
            if state not in ('idle', 'discovering', 'connecting', 'pin_required', 'streaming'):
                raise ValueError('Unknown AirPlay state')
            self.sender_state = 'ready' if state == 'idle' else state
            self.streams = [dict(device=str(s.get('device') or s.get('device_ip') or 'AirPlay')[:120],
                                 address=str(s.get('device_ip') or ''), state=str(s.get('state') or ''),
                                 hasAudio=bool(s.get('has_audio')), muted=bool(s.get('audio_muted')),
                                 credentialKind='password' if s.get('credential_kind') == 'password' else 'pin')
                            for s in (response.get('streams') or [])[:16] if isinstance(s, dict)]
            self.sender_error = self.clean_error(response.get('error') or self.sender_error)
        self.publish()

    def sender_failed(self, error):
        self.stop_sender()
        self.sender_state = 'error'
        self.sender_error = error
        self.devices = []
        self.publish()

    def command(self, request):
        action = request['action']
        data = request.get('data', {})
        self.apply_preferences(data)
        if action == 'watch':
            self.watching = bool(data.get('enabled'))
            if self.watching:
                self.start_sender()
                self.scan_until = time.monotonic() + 6
        elif action == 'refresh':
            self.sender_error = ''
            self.start_sender()
            self.scan_until = time.monotonic() + 6
            self.next_poll = 0
        elif action == 'connect':
            if self.streams or self.sender_state in ('starting', 'connecting', 'pin_required', 'streaming'):
                raise ValueError('Stop the current mirror before choosing another display.')
            device = next((d for d in self.devices if d['key'] == data.get('key')), None)
            if device is None:
                raise ValueError('The AirPlay display is no longer in the discovered list. Search again.')
            self.sender_error = ''
            self.enqueue('connect', target=device['address'], port=device['port'])
            self.sender_state = 'connecting'
        elif action == 'credential':
            stream = next((s for s in self.streams if s['state'] == 'pin_required'), None)
            credential = data.get('value')
            if stream is None or not isinstance(credential, str) or not 1 <= len(credential) <= 128 or '\x00' in credential:
                raise ValueError('There is no pending AirPlay PIN/password request, or the value is invalid.')
            self.sender_error = ''
            self.credentials_to_hide.append(credential)
            self.enqueue('connect', target=stream['address'], pin=credential)
            self.sender_state = 'connecting'
            self.streams = [dict(s, state='connecting') if s is stream else s for s in self.streams]
        elif action == 'disconnect':
            self.queue.clear()
            if self.sender:
                self.enqueue('disconnect')
            self.sender_error = ''
        elif action == 'audio':
            if not any(s['state'] == 'streaming' and s['hasAudio'] for s in self.streams):
                raise ValueError('The AirPlay display has no active audio stream.')
            self.enqueue('unmute' if data.get('enabled') else 'mute')
        elif action == 'receive':
            if data.get('enabled'):
                self.start_receiver(data.get('name', 'MacShell'))
            else:
                self.stop_process('receiver')
                self.receiver_state = 'off'
                self.receiver_error = self.receiver_pin = self.receiver_client = ''
        elif action != 'status':
            raise ValueError('Unknown screen mirroring action.')
        self.publish()

    def apply_preferences(self, data):
        if 'fps' in data:
            value = int(data['fps'])
            if not 1 <= value <= 60:
                raise ValueError('AirPlay FPS must be between 1 and 60.')
            if self.sender and value != self.fps:
                raise ValueError('Stop Screen Mirroring before changing FPS.')
            self.fps = value
        if 'volumePercent' in data:
            value = int(data['volumePercent'])
            if not 1 <= value <= 100:
                raise ValueError('AirPlay volume must be between 1 and 100 percent.')
            self.volume_percent = value

    def tick(self):
        now = time.monotonic()
        if self.rpc and now > self.rpc['deadline']:
            self.sender_failed('AirPlay sender did not respond. Try searching again.')
        if self.sender:
            if self.sender.poll() is not None:
                self.sender_failed('AirPlay sender stopped. Check Doubletake and its GStreamer dependencies.')
            elif self.sender_state == 'starting' and now - self.started['sender'] > 8:
                self.sender_failed('AirPlay sender could not open its control socket.')
            elif not self.rpc and Path(self.socket_path).exists() and now >= self.next_poll:
                if self.queue:
                    request = self.queue.popleft()
                else:
                    request = dict(cmd='status')
                    if self.watching:
                        self.queue.append(dict(cmd='devices'))
                    self.next_poll = now + 1
                try:
                    self.begin_rpc(request)
                except OSError:
                    self.sender_failed('Could not contact the AirPlay sender.')
            if self.sender_state == 'ready' and not self.watching and not self.queue and not self.rpc:
                self.stop_sender()
                self.sender_state = 'off'
        if self.receiver:
            if self.receiver.poll() is not None:
                self.stop_process('receiver')
                self.receiver_state = 'error'
                self.receiver_error = self.receiver_error or 'AirPlay receiver stopped. Check UxPlay and its GStreamer dependencies.'
                self.receiver_pin = self.receiver_client = ''
            elif self.receiver_state == 'error' or self.receiver_state == 'starting' and now - self.started['receiver'] > 10:
                self.stop_process('receiver')
                self.receiver_state = 'error'
                self.receiver_error = self.receiver_error or 'AirPlay receiver did not advertise on the network.'
                self.receiver_pin = self.receiver_client = ''
        self.publish()

    def close(self):
        self.stop_sender()
        self.stop_process('receiver')
        self.temporary.cleanup()


if __name__ == '__main__':
    os.umask(0o077)
    ScreenMirroring().run()

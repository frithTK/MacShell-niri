#!/usr/bin/env python3
"""Owned AirDrop sessions through the pinned Owly JSON interface."""
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import subprocess
import time
from urllib.parse import unquote, urlparse
import uuid

from line_service import LineService, protect_child


def executable():
    runtime = Path(os.environ.get('XDG_DATA_HOME', Path.home() / '.local/share')) / 'macshell-niri/runtime/bin/owly'
    # Our runtime has the machine interface; an ordinary distro CLI may not.
    return str(runtime) if runtime.is_file() and os.access(runtime, os.X_OK) else shutil.which('owly')


def text(value, limit=200):
    return re.sub(r'[\x00-\x1f\x7f]', '', str(value or ''))[:limit]


def local_files(values):
    if not isinstance(values, list) or not 1 <= len(values) <= 100:
        raise ValueError('Choose between 1 and 100 files.')
    files = []
    for value in values:
        if not isinstance(value, str) or len(value) > 8192 or '\0' in value:
            raise ValueError('Invalid file path.')
        parsed = urlparse(value)
        if parsed.scheme == 'file' and parsed.netloc in ('', 'localhost'):
            path = Path(unquote(parsed.path))
        elif not parsed.scheme:
            path = Path(value)
        else:
            raise ValueError('Choose local files.')
        path = path.expanduser().resolve(strict=True)
        if not path.is_file() or not os.access(path, os.R_OK):
            raise ValueError('A selected file is unavailable. Choose files again.')
        if str(path) not in files:
            files.append(str(path))
    return files


class AirDrop(LineService):
    def __init__(self):
        super().__init__()
        self.program = None
        self.available = False
        self.configured = False
        self.mode = ''
        self.status = 'off'
        self.error = ''
        self.notice = ''
        self.interface = ''
        self.name = 'MacShell'
        self.devices = {}
        self.files = []
        self.file_details = []
        self.pending = None
        self.transfer = 'idle'
        self.progress = dict(sent=0, total=0)
        self.results = []
        self.receiving = False
        self.scanning = False
        self.blocked = False
        self.deadline = 0
        self.epoch = ''
        self.processes = {}
        self.readers = {}
        self.last_publication = None
        self.receive_id = None
        self.folder = Path(os.environ.get('MACSHELL_AIRDROP_DOWNLOADS', str(Path.home() / 'Downloads/AirDrop'))).expanduser().resolve()

    def wait_timeout(self):
        return .15 if self.processes else None

    def publish(self):
        state = dict(type='state', available=self.available, configured=self.configured, mode=self.mode,
                     canStart=self.configured and self.mode == 'shared',
                     status=self.status, error=self.error, notice=self.notice, devices=list(self.devices.values()),
                     files=self.file_details,
                     pending=self.pending, transfer=self.transfer, progress=self.progress, results=self.results,
                     receiving=self.receiving, scanning=self.scanning, folder=str(self.folder), blocked=self.blocked)
        if state != self.last_publication:
            self.last_publication = state
            self.emit(**state)

    def probe(self):
        if self.processes:
            return
        self.program = executable()
        self.available = self.configured = False
        self.error = self.notice = ''
        if not self.program:
            self.notice = 'Install the MacShell Owly backend to use AirDrop.'
            return
        try:
            result = subprocess.run([self.program, 'macshell', 'capabilities'], capture_output=True, text=True, timeout=5)
            if result.returncode or json.loads(result.stdout).get('protocol') != 1:
                raise ValueError('The installed Owly needs the MacShell machine interface.')
            self.available = True
            result = subprocess.run([self.program, 'doctor', '--json'], capture_output=True, text=True, timeout=8)
            report = json.loads(result.stdout)
            self.mode = report.get('mode') or ''
            missing = report.get('missing') or []
            self.configured = bool(report.get('hardware')) and self.mode in ('shared', 'exclusive', 'active-monitor') and not missing
            self.notice = ' '.join('Complete AirDrop system-service setup, then try again.' if item.get('id') == 'backend' else text(item.get('say')) for item in missing[:3])
            if self.configured and self.mode != 'shared':
                self.notice = 'AirDrop on this adapter disconnects Wi-Fi and interrupts internet calls. MacShell blocks this mode.'
            if not report.get('hardware') and not self.notice:
                self.notice = 'This Wi-Fi adapter is not supported by Owly.'
        except (OSError, ValueError, subprocess.TimeoutExpired) as error:
            self.notice = text(error)

    def spawn(self, kind, arguments):
        if kind in self.processes:
            raise ValueError('Wait for the current AirDrop operation.')
        child = subprocess.Popen([self.program, 'macshell', *arguments], stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, preexec_fn=protect_child,
                                 env=dict(os.environ, TOKIO_WORKER_THREADS='2'))
        self.processes[kind] = dict(child=child, error='', terminal=False, started=time.monotonic())
        for source, stream in ((child.stdout, 'stdout'), (child.stderr, 'stderr')):
            os.set_blocking(source.fileno(), False)
            self.readers[source] = dict(kind=kind, stream=stream, buffer=b'')
            self.selector.register(source, selectors.EVENT_READ, self.read_child)

    def stop_process(self, kind):
        record = self.processes.pop(kind, None)
        if not record:
            return
        child = record['child']
        if child.poll() is None:
            child.send_signal(signal.SIGINT)
            try:
                child.wait(timeout=10 if kind == 'radio' else 2)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=2)
        for source in (child.stdout, child.stderr):
            if source in self.readers:
                self.selector.unregister(source)
                self.readers.pop(source)
            source.close()
        child.stdin.close()

    def stop(self):
        self.status = 'stopping'
        self.publish()
        for kind in ('browse', 'send', 'receive', 'radio'):
            self.stop_process(kind)
        self.status = 'off'
        self.pending = None
        self.receiving = self.scanning = False
        self.receive_id = None
        self.deadline = 0
        self.devices = {}
        if self.transfer in ('waiting', 'sending', 'receiving'):
            self.transfer = 'cancelled'

    def fail(self, message):
        self.stop()
        self.status = 'error'
        self.error = text(message)

    def read_child(self, source):
        if source not in self.readers:
            return
        record = self.readers[source]
        data = os.read(source.fileno(), 65536)
        if not data:
            self.selector.unregister(source)
            self.readers.pop(source)
            return
        if record['stream'] == 'stderr':
            if record['kind'] in self.processes:
                self.processes[record['kind']]['error'] = text(data.decode('utf-8', 'replace'), 500)
            return
        record['buffer'] += data
        if len(record['buffer']) > 1048576:
            self.fail('AirDrop returned an invalid response.')
            return
        while b'\n' in record['buffer']:
            raw, record['buffer'] = record['buffer'].split(b'\n', 1)
            try:
                message = json.loads(raw)
                if not isinstance(message, dict):
                    raise ValueError('Invalid event')
                self.event(record['kind'], message)
            except (ValueError, TypeError, KeyError, OSError):
                self.fail('AirDrop returned an invalid response.')
                break
        self.publish()

    def common_args(self):
        return ['--iface', self.interface, '--name', self.name]

    def scan(self):
        if self.status != 'ready' or 'browse' in self.processes or 'send' in self.processes:
            return
        self.devices = {}
        self.scanning = True
        self.spawn('browse', ['browse', *self.common_args(), '--seconds', '10'])

    def event(self, kind, message):
        event = message.get('event')
        if kind == 'radio' and event == 'radio_ready' and self.status == 'starting':
            interface = message.get('interface')
            if not isinstance(interface, str) or not re.fullmatch(r'[a-zA-Z0-9_.-]{1,15}', interface):
                raise ValueError('Invalid AirDrop interface')
            self.interface = interface
            self.status = 'ready'
            self.folder.mkdir(parents=True, exist_ok=True, mode=0o700)
            self.spawn('receive', ['receive', *self.common_args(), '--dir', str(self.folder)])
            self.scan()
        elif kind == 'radio' and event == 'radio_stopped':
            self.processes[kind]['terminal'] = True
        elif kind == 'browse' and event == 'device':
            key, flags = message['key'], message['flags']
            if not isinstance(key, str) or len(key) > 150 or not re.fullmatch(r'\[fe80:[0-9a-fA-F:%._-]+\]:[0-9]{1,5}', key):
                raise ValueError('Invalid AirDrop device')
            if isinstance(flags, bool) or not isinstance(flags, int) or not 0 <= flags <= 0xffffffff:
                raise ValueError('Invalid AirDrop flags')
            if len(self.devices) < 100:
                self.devices[key] = dict(key=key, name=text(message.get('name')) or 'Apple device', flags=flags)
        elif kind == 'browse' and event == 'scan_done':
            self.scanning = False
            self.processes[kind]['terminal'] = True
        elif kind == 'receive' and event == 'receiver_ready':
            self.receiving = True
        elif kind == 'receive' and event == 'request':
            native_id = message['id']
            if isinstance(native_id, bool) or not isinstance(native_id, int) or not 0 <= native_id <= 9007199254740991:
                raise ValueError('Invalid request')
            if self.receive_id is not None or self.pending:
                self.processes['receive']['child'].stdin.write(json.dumps(dict(id=native_id, accept=False)).encode() + b'\n')
                self.processes['receive']['child'].stdin.flush()
                return
            files = message.get('files') or []
            urls = message.get('urls') or []
            if len(files) + len(urls) > 100:
                raise ValueError('Too many items')
            self.pending = dict(key=self.epoch + ':' + str(native_id), id=native_id, name=text(message.get('name')),
                                files=[dict(name=text(item.get('name'))) for item in files], urls=[text(url, 500) for url in urls],
                                expires=time.monotonic() + 14)
        elif kind == 'receive' and event in ('answered', 'withdrawn'):
            if self.pending and message.get('id') == self.pending['id']:
                if event == 'answered' and message.get('accepted') is True:
                    self.receive_id = self.pending['id']
                    self.transfer = 'receiving'
                self.pending = None
            if message.get('id') == self.receive_id and (event == 'withdrawn' or message.get('accepted') is False):
                self.receive_id = None
                self.transfer = 'cancelled'
        elif kind == 'receive' and event in ('received', 'received_urls', 'receive_failed'):
            if message.get('id') == self.receive_id:
                self.receive_id = None
            if event == 'receive_failed':
                self.transfer = 'failed'
                self.error = text(message.get('reason')) or 'AirDrop could not receive this transfer.'
            else:
                self.transfer = 'received'
                self.results = [text(Path(path).name) for path in message.get('paths', [])[:100]] if event == 'received' else [text(url, 500) for url in message.get('urls', [])[:100]]
        elif kind == 'send' and event == 'accepted':
            self.transfer = 'sending'
        elif kind == 'send' and event == 'progress':
            sent, total = message['sent'], message['total']
            if not all(isinstance(value, int) and not isinstance(value, bool) and 0 <= value <= 9007199254740991 for value in (sent, total)) or sent > total:
                raise ValueError('Invalid progress')
            self.progress = dict(sent=sent, total=total)
        elif kind == 'send' and event in ('delivered', 'declined', 'failed'):
            self.transfer = event
            self.processes[kind]['terminal'] = True
            if event == 'failed':
                self.error = text(message.get('reason')) or 'AirDrop could not send these files.'

    def command(self, request):
        action, data = request['action'], request.get('data', {})
        if action == 'probe':
            self.probe()
        elif action == 'blocked':
            self.blocked = bool(data.get('enabled'))
        elif action == 'start':
            if self.blocked:
                raise ValueError('Stop AirPlay before enabling AirDrop.')
            if self.processes:
                raise ValueError('AirDrop is already enabled.')
            self.probe()
            if not self.configured:
                raise ValueError(self.notice or 'The AirDrop backend is not ready.')
            # A consent flag from an old UI must never allow taking Wi-Fi down.
            if self.mode != 'shared':
                raise ValueError('AirDrop would disconnect Wi-Fi and interrupt calls on this adapter. This mode is disabled.')
            self.name = text(data.get('name')).strip()[:60]
            if not self.name:
                raise ValueError('Choose an AirDrop name.')
            self.epoch = uuid.uuid4().hex
            self.error = ''
            self.transfer = 'idle'
            self.status = 'starting'
            self.deadline = time.monotonic() + 600
            try:
                self.spawn('radio', ['radio', '--seconds', '600'])
            except OSError:
                self.status = 'error'
                self.deadline = 0
                self.error = 'AirDrop could not start. Check the backend setup and try again.'
                raise ValueError(self.error)
        elif action == 'stop':
            self.stop()
        elif action == 'scan':
            self.scan()
        elif action == 'files':
            if 'send' in self.processes:
                raise ValueError('Wait for the transfer or cancel it first.')
            self.files = local_files(data.get('paths')) if data.get('paths') else []
            self.file_details = [dict(name=Path(path).name, size=Path(path).stat().st_size) for path in self.files]
        elif action == 'send':
            if self.status != 'ready' or self.pending or self.receive_id is not None:
                raise ValueError('AirDrop is not ready for a new transfer.')
            device = self.devices.get(data.get('key'))
            if not device:
                raise ValueError('Choose a discovered device. Search again if it disappeared.')
            self.files = local_files(self.files)
            self.error = ''
            self.transfer = 'waiting'
            self.results = []
            self.progress = dict(sent=0, total=0)
            self.stop_process('browse')
            self.scanning = False
            self.spawn('send', ['send', *self.common_args(), '--address', device['key'], '--flags', str(device['flags']), '--', *self.files])
        elif action == 'answer':
            if not self.pending or data.get('key') != self.pending['key'] or time.monotonic() >= self.pending['expires']:
                raise ValueError('This request has expired.')
            child = self.processes['receive']['child']
            child.stdin.write(json.dumps(dict(id=self.pending['id'], accept=data.get('accept') is True)).encode() + b'\n')
            child.stdin.flush()
            if data.get('accept') is True:
                self.receive_id = self.pending['id']
                self.transfer = 'receiving'
                self.results = []
            self.pending = None
        elif action == 'cancel':
            self.stop_process('send')
            self.transfer = 'cancelled'
        elif action != 'status':
            raise ValueError('Unknown AirDrop action.')
        self.publish()

    def tick(self):
        now = time.monotonic()
        if self.pending and now >= self.pending['expires']:
            self.pending = None
        for kind, record in list(self.processes.items()):
            code = record['child'].poll()
            if code is None:
                if kind == 'radio' and self.status == 'starting' and now - record['started'] > 90:
                    self.fail('AirDrop did not start. Check the authorization dialog and try again.')
                    break
                continue
            # Drain queued events before interpreting process completion.
            for source in (record['child'].stdout, record['child'].stderr):
                if source in self.readers:
                    self.read_child(source)
            if kind not in self.processes:
                break
            if kind == 'radio':
                if record['terminal']:
                    self.stop()
                else:
                    self.fail(record['error'] or 'AirDrop radio stopped; Wi-Fi is being restored.')
                break
            self.stop_process(kind)
            if kind == 'browse':
                self.scanning = False
                if code:
                    self.error = record['error'] or 'AirDrop search failed.'
            elif kind == 'receive':
                self.receiving = False
                self.pending = None
                self.error = record['error'] or 'AirDrop receiver stopped. Disable and enable AirDrop to retry.'
            elif kind == 'send' and not record['terminal']:
                self.transfer = 'failed'
                self.error = record['error'] or 'The transfer ended without delivery confirmation.'
        if self.deadline and now >= self.deadline and self.processes:
            self.stop()
        self.publish()

    def close(self):
        self.stop()


if __name__ == '__main__':
    os.umask(0o077)
    AirDrop().run()

#!/usr/bin/env python3
"""Exercise online/cached/error/cancelled currency conversion against an owned HTTP server."""
import argparse
import atexit
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import uuid

project = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(project))
from scripts.install_niri import quickshell


def nested_session():
    if len(sys.argv) > 1 and sys.argv[1] == '--nested-child':
        _, _, directory, parent_display, parent_socket, *arguments = sys.argv
        display, address = os.environ.get('WAYLAND_DISPLAY'), os.environ.get('NIRI_SOCKET')
        if not display or display == parent_display or not address or address == parent_socket:
            raise RuntimeError('Refusing to test a non-isolated compositor')
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.connect(address)
            pid, uid, _ = struct.unpack('3i', conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
        token = ('MACSHELL_CURRENCY_TEST_TOKEN=' + os.environ['MACSHELL_CURRENCY_TEST_TOKEN']).encode()
        if uid != os.getuid() or token not in Path('/proc', str(pid), 'environ').read_bytes().split(b'\0'):
            raise RuntimeError('Nested niri socket does not belong to the test compositor')
        os.environ['MACSHELL_CURRENCY_TEST_RESULT'] = str(Path(directory) / 'result')
        def report_error(kind, value, tb):
            Path(os.environ['MACSHELL_CURRENCY_TEST_RESULT']).write_text(''.join(traceback.format_exception(kind, value, tb)))
            sys.__excepthook__(kind, value, tb)
        sys.excepthook = report_error
        atexit.register(lambda: subprocess.run(['niri', 'msg', 'action', 'quit', '--skip-confirmation'], capture_output=True, timeout=8))
        sys.argv = [sys.argv[0], *arguments]
        return
    display, address = os.environ.get('WAYLAND_DISPLAY'), os.environ.get('NIRI_SOCKET')
    if not display or not address:
        raise RuntimeError('A parent Wayland/niri session is required to start nested niri')
    with tempfile.TemporaryDirectory(prefix='macshell-currency-nested-') as directory:
        root = Path(directory)
        config = root / 'niri.kdl'
        config.write_text('hotkey-overlay { skip-at-startup; }\n')
        command = ['niri', '-c', str(config), '--', sys.executable, str(Path(__file__).resolve()),
                   '--nested-child', directory, display, address, *sys.argv[1:]]
        env = dict(os.environ, MACSHELL_CURRENCY_TEST_TOKEN=uuid.uuid4().hex)
        result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=240)
        sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)
        if result.returncode:
            raise SystemExit(result.returncode)
        if not (root / 'result').is_file() or (root / 'result').read_text() != 'PASS':
            detail = (root / 'result').read_text() if (root / 'result').is_file() else 'no child result'
            raise RuntimeError('Nested currency test did not complete: ' + detail)
        print('MACSHELL_CURRENCY_NESTED_PASS')
    raise SystemExit(0)


nested_session()

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--capture', type=Path)
parser.add_argument('--live', action='store_true', help='Smoke-test the real HTTPS provider with a fresh temporary cache')
parser.add_argument('--rust', action='store_true', help='Build and test the Rust currency backend')
args = parser.parse_args()
if args.capture: args.capture.mkdir(parents=True, exist_ok=True)
source = dict(mode='online', ruble=80, calls=[])
today = datetime.now(timezone.utc).date()
metadata = [dict(iso_code=code, name=name) for code, name in [('USD', 'US Dollar'), ('RUB', 'Russian Ruble'), ('EUR', 'Euro')]]

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        source['calls'].append(self.path)
        mode = source['mode']
        if mode == 'slow': time.sleep(2)
        if mode == 'offline':
            self.send_error(503)
            return
        rows = [dict(base='USD', quote=code, rate=rate, date=str(today - timedelta(days=1) if code == 'EUR' else today))
                for code, rate in [('USD', 1), ('RUB', source['ruble']), ('EUR', .8)]]
        if mode == 'invalid': rows[1]['rate'] = 0
        value = metadata if self.path == '/currencies' else rows
        data = json.dumps(value).encode()
        try:
            self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(data)))
            self.end_headers(); self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError): pass

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
server.daemon_threads = True
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='macshell-currency-native-') as directory:
        root = Path(directory)
        shell = root / 'shell'
        shutil.copytree(project / 'MacShell', shell)
        if args.rust:
            build_env = dict(os.environ)
            if not args.live:
                build_env['MACSHELL_CURRENCY_TEST_API'] = 'http://127.0.0.1:' + str(server.server_port) + '/'
            else:
                build_env.pop('MACSHELL_CURRENCY_TEST_API', None)
            build = subprocess.run(['cargo', 'build', '--offline', '--locked', '--manifest-path', str(project / 'native/currency-fetch/Cargo.toml'), '--target-dir', str(root / 'rust-build')], env=build_env, capture_output=True, text=True, timeout=180)
            if build.returncode: raise RuntimeError('Rust currency build failed: ' + build.stderr[-5000:])
            shutil.copy2(root / 'rust-build/debug/macshell-currency-fetch', shell / 'currency-fetch-rust')
            if not args.live:
                test_cache = root / 'compat/rates.json'
                response = subprocess.run([str(shell / 'currency-fetch-rust'), '7', '--cache', str(test_cache)], capture_output=True, text=True, check=True, timeout=20)
                result = json.loads(response.stdout.splitlines()[-1])
                from MacShell.currency_fetch import load_cache
                assert result['success'] and load_cache(test_cache, int(time.time() * 1000)) == result['snapshot'], 'Python must read the Rust cache'
                assert test_cache.stat().st_mode & 0o777 == 0o600
                source['calls'].clear()
        path = shell / 'shell.qml'
        qml = path.read_text().replace('import QtQuick\n', 'import QtQuick\nimport QtQuick.Window\nimport QtTest\n', 1)
        qml = qml.replace('ShellRoot {', 'ShellRoot {\n' + (project / 'tests/currency-native.qml').read_text(), 1)
        path.write_text(qml)
        path = shell / 'currency_fetch.py'
        if not args.live:
            path.write_text(path.read_text().replace("API = 'https://api.frankfurter.dev/v2/'", "API = 'http://127.0.0.1:" + str(server.server_port) + "/'"))
        # Accelerate the production watchdog to check its kill/retry path without a 25s pause.
        path = shell / 'CurrencyRates.qml'
        qml = path.read_text(); assert 'interval: 25000' in qml
        if not args.live: path.write_text(qml.replace('interval: 25000', 'interval: 700'))
        for name in ('cache', 'config', 'settings/macbar', 'settings/macdock'):
            (root / name).mkdir(parents=True)
        (root / 'settings/macbar/settings.json').write_text(json.dumps(dict(barEnabled=False, spotlightEnabled=False, ccEnabled=False,
            notificationsEnabled=False, clipHistory=False, autoContrast=False, barGlass=False, statsMetrics=[])))
        (root / 'settings/macdock/settings.json').write_text(json.dumps(dict(dockEnabled=False, windowCapture=False)))
        env = dict(os.environ, QT_QPA_PLATFORM='wayland', QT_QPA_PLATFORMTHEME='', QT_QUICK_CONTROLS_STYLE='Basic',
            XDG_CACHE_HOME=str(root / 'cache'), XDG_CONFIG_HOME=str(root / 'config'), MACSHELL_SETTINGS_HOME=str(root / 'settings'),
            LANG='C.UTF-8', LANGUAGE='en', LC_ALL='C.UTF-8', NIRI_SOCKET=str(root / 'no-session'), DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'), DBUS_SYSTEM_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'))
        qs = quickshell()
        log_path = root / 'quickshell.log'
        with log_path.open('w') as log:
            process = subprocess.Popen([qs, '-p', str(shell)], env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            def call(method, *values):
                if process.poll() is not None: raise RuntimeError('Currency probe exited; see ' + str(log_path))
                run = subprocess.run([qs, '-p', str(shell), 'ipc', 'call', 'currencyProbe', method, *map(str, values)],
                    env=env, capture_output=True, text=True, timeout=3)
                if run.returncode: raise RuntimeError(run.stderr.strip() or 'Probe not ready')
                return json.loads(run.stdout) if method == 'state' else run.stdout
            def wait(predicate, label, timeout=5):
                deadline = time.monotonic() + timeout
                state = {}
                while time.monotonic() < deadline:
                    try:
                        state = call('state')
                        if predicate(state): return state
                    except (RuntimeError, json.JSONDecodeError, subprocess.TimeoutExpired):
                        if process.poll() is not None: raise
                    time.sleep(.05)
                raise RuntimeError(label + ': ' + json.dumps(state))
            def closed():
                call('hide'); return wait(lambda s: not s['enabled'] and not s['loading'] and s['pid'] <= 0, 'closed currency releases helper')
            cache = root / 'cache/macshell-niri/currency-rates.json'
            try:
                wait(lambda s: s['ready'], 'shell startup', 10)
                call('open'); wait(lambda s: s['visible'] and s['frames'] > 0, 'first Calculator frame')
                call('mode', 'convert'); call('group', 'length')
                time.sleep(.15); assert not source['calls'], 'Local units must not fetch rates'
                call('group', 'currency'); call('enterAmount')
                if args.live:
                    state = wait(lambda s: not s['loading'] and s['available'] and s['pid'] <= 0 and s['unit'] == 'RUB', 'real HTTPS conversion', 23)
                    assert len(state['snapshot']['rates']) > 2 and state['snapshot']['provider'] == 'frankfurter-v2'
                    assert abs(float(state['result']) - 100 * state['snapshot']['rates']['RUB']) < 1e-8
                    assert cache.exists() and not source['calls'], 'Live smoke must use the HTTPS provider'
                    print('MACSHELL_CURRENCY_LIVE_PASS:', json.dumps(dict(currencies=len(state['snapshot']['rates']), pair='USD/RUB', date=state['date'], fetchedAt=state['snapshot']['fetchedAt'])))
                    closed(); call('quit'); process.wait(timeout=5)
                else:
                    wait(lambda s: not s['loading'] and s['pid'] <= 0 and s['result'] == '8000' and s['unit'] == 'RUB', 'online conversion')
                    assert len(source['calls']) == 2 and cache.exists()
                    call('compute'); wait(lambda s: s['history'] == 1, 'dated currency history')
                    call('pair', 'EUR', 'RUB')
                    wait(lambda s: s['result'] == '10000' and ' – ' in s['date'], 'cross-rate and both observation dates')
                    call('swap'); wait(lambda s: s['result'] == '1' and s['from'] == 'RUB', 'real Swap action')
                    call('pair', 'USD', 'RUB')
                    for dark, name in [('true', 'dark'), ('false', 'light')]:
                        call('theme', dark); time.sleep(.15)
                        if args.capture:
                            picture = str(args.capture.resolve() / ('calculator-currency-' + name + '.png'))
                            call('capture', picture); wait(lambda s: s['captured'] == picture, 'currency screenshot')
                    count = len(source['calls'])
                    closed(); call('resetMemory'); call('open')
                    wait(lambda s: not s['loading'] and s['pid'] <= 0 and s['result'] == '8000', 'cache restores after controller reset')
                    assert len(source['calls']) == count, 'Fresh cache must skip network'
                    before = cache.read_bytes(); source['mode'] = 'offline'; call('refresh')
                    wait(lambda s: not s['loading'] and s['error'] and s['result'] == '8000' and 'saved rates' in s['status'], 'offline cached conversion')
                    assert cache.read_bytes() == before
                    source['mode'] = 'invalid'; call('refresh')
                    wait(lambda s: not s['loading'] and s['error'] and s['pid'] <= 0, 'invalid response rejected')
                    assert cache.read_bytes() == before
                    source['mode'] = 'online'; source['ruble'] = 90; call('refresh')
                    wait(lambda s: not s['loading'] and not s['error'] and s['result'] == '9000' and s['pid'] <= 0, 'Refresh updates amount without Enter')
                    call('stale'); assert call('state')['result'] == '9000', 'Late epoch must not change rates'
                    source['mode'] = 'slow'; call('refresh')
                    worker = wait(lambda s: s['loading'] and s['pid'] > 0, 'owned request running')['pid']
                    closed()
                    assert not Path('/proc', str(worker)).exists(), 'Closing must stop the request PID'
                    call('open'); call('refresh')
                    wait(lambda s: not s['loading'] and 'timed out' in s['error'] and s['pid'] <= 0, 'watchdog terminates request')
                    closed(); call('resetMemory'); cache.unlink(); source['mode'] = 'offline'; call('open')
                    wait(lambda s: not s['loading'] and s['error'] and not s['available'] and s['result'] == '—' and not s['copyEnabled'], 'offline without cache never invents rates')
                    assert not cache.exists()
                    source['mode'] = 'online'; call('refresh')
                    wait(lambda s: not s['loading'] and s['result'] == '9000' and s['pid'] <= 0, 'recover after network returns')
                    count = len(source['calls'])
                    for _ in range(5):
                        closed(); call('open'); wait(lambda s: s['visible'] and not s['loading'] and s['pid'] <= 0, 'memory cache reopen')
                    assert len(source['calls']) == count
                    closed(); call('quit'); process.wait(timeout=5)
            finally:
                if process.poll() is None:
                    process.terminate(); process.wait(timeout=5)
        log = log_path.read_text()
        assert not re.search(r'TypeError|ReferenceError|Binding loop|Unable to assign|Failed to load configuration|CURRENCY_NATIVE_TIMEOUT', log), log[-4000:]
        if not args.live: print('MACSHELL_CURRENCY_NATIVE_PASS: online/cached cross-rates, dates, input, Swap/Refresh, both themes, offline/invalid recovery, timeout, cancellation, stale epoch and five reopen cycles; only owned HTTP and temporary cache were used.')
        Path(os.environ['MACSHELL_CURRENCY_TEST_RESULT']).write_text('PASS')
finally:
    server.shutdown(); server.server_close()

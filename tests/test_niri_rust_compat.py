"""Compare both bridges against a private fake niri; no desktop data is read."""
import copy
import json
import multiprocessing
import os
from pathlib import Path
import queue
import select
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from MacShell.niri_ipc import State
RUST = os.environ.get('MACSHELL_NIRI_RUST_BINARY', '')

OUTPUTS = {
    'A-disabled': {'logical': None},
    'eDP-test': {'logical': {'x': 200, 'y': -40, 'width': 1280, 'height': 800, 'scale': 1.5},
                 'make': 'Demo', 'model': 'Screen', 'serial': 'fake', 'modes': [
                     {'width': 1920, 'height': 1200, 'refresh_rate': 60000}], 'current_mode': 0},
}
WORKSPACES = [
    {'id': 10, 'idx': 1, 'output': 'eDP-test', 'is_active': True, 'is_focused': True, 'name': None},
    {'id': 11, 'idx': 2, 'output': 'eDP-test', 'is_active': False, 'is_focused': False, 'name': 'Fake'},
]
WINDOW = {'id': 42, 'app_id': 'demo', 'title': 'Synthetic 🌿', 'workspace_id': 10,
          'is_focused': True, 'is_floating': False,
          'layout': {'tile_pos_in_workspace_view': [15.5, 20], 'window_offset_in_tile': [2, 3],
                     'window_size': [400, 300]}}


class FakeNiri:
    def __init__(self, address, windows=None):
        self.listener = socket.socket(socket.AF_UNIX)
        self.listener.bind(address); self.listener.listen(); self.listener.settimeout(.1)
        self.streams = queue.Queue()
        self.actions = queue.Queue()
        self.outputs = copy.deepcopy(OUTPUTS)
        self.windows = copy.deepcopy(windows if windows is not None else [WINDOW])
        self.stop = threading.Event()
        self.connections = []
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        while not self.stop.is_set():
            try: conn, _ = self.listener.accept()
            except socket.timeout: continue
            except OSError: break
            threading.Thread(target=self.handle, args=(conn,), daemon=True).start()

    def handle(self, conn):
        try:
            request = json.loads(conn.makefile('rb').readline())
            if request == 'EventStream':
                self.connections.append(conn)
                initial = [{'Ok': 'Handled'}, {'WorkspacesChanged': {'workspaces': WORKSPACES}},
                           {'WindowsChanged': {'windows': self.windows}}]
                conn.sendall(('\n'.join(json.dumps(x, ensure_ascii=False) for x in initial) + '\n').encode())
                self.streams.put(conn)
                self.stop.wait(20)
            elif request == 'Outputs':
                conn.sendall((json.dumps({'Ok': {'Outputs': self.outputs}}) + '\n').encode())
            else:
                self.actions.put(request)
                reply = {'Err': 'synthetic failure'} if request == {'Bad': True} else {'Ok': 'Handled'}
                conn.sendall((json.dumps(reply) + '\n').encode())
        except (OSError, ValueError):
            pass
        finally:
            conn.close()

    def close(self):
        self.stop.set()
        for conn in self.connections:
            try: conn.shutdown(socket.SHUT_RDWR)
            except OSError: pass
        self.listener.close()
        self.thread.join(timeout=2)


class Runner:
    def __init__(self, command, address):
        self.process = subprocess.Popen(command, env=dict(os.environ, NIRI_SOCKET=address),
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.buffer = b''
        self.session = None
        self.uses_session = command[0] != sys.executable

    def next(self, predicate, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            while b'\n' in self.buffer:
                line, self.buffer = self.buffer.split(b'\n', 1)
                value = json.loads(line)
                if value.get('bridgeSession'): self.session = value['bridgeSession']
                if predicate(value): return value
            if select.select([self.process.stdout], [], [], max(0, deadline-time.monotonic()))[0]:
                chunk = os.read(self.process.stdout.fileno(), 262144)
                if not chunk: break
                self.buffer += chunk
        raise AssertionError('Bridge did not emit expected message')

    def command(self, command, session=None):
        if self.uses_session:
            command = {'bridgeSession': self.session if session is None else session, 'request': command}
        self.process.stdin.write((json.dumps(command) + '\n').encode()); self.process.stdin.flush()

    def close(self):
        self.process.stdin.close()
        try: self.process.wait(timeout=4)
        except subprocess.TimeoutExpired:
            self.process.kill(); self.process.wait()
            raise AssertionError('Bridge did not exit after stdin closed')
        finally:
            self.process.stdout.close(); self.process.stderr.close()


def external_server(address, label, ready, actions, stop):
    server = FakeNiri(address)
    ready.put(label)
    try:
        while not stop.is_set():
            try: action = server.actions.get(timeout=.05)
            except queue.Empty: continue
            actions.put((label, action))
    finally:
        server.close()


@unittest.skipUnless(RUST and Path(RUST).is_file(), 'Set MACSHELL_NIRI_RUST_BINARY to the built prototype')
class NiriRustCompatibilityTests(unittest.TestCase):
    def exercise(self, command):
        with tempfile.TemporaryDirectory() as directory:
            address = str(Path(directory) / 'fake.sock')
            server = FakeNiri(address); runner = Runner(command, address)
            trace = []
            try:
                stream = server.streams.get(timeout=4)
                initial = runner.next(lambda m: len(m.get('state', {}).get('windows', [])) == 1)
                trace.append(initial)
                changed = dict(WINDOW, title='Updated synthetic title')
                payload = json.dumps({'WindowOpenedOrChanged': {'window': changed}}).encode() + b'\n'
                stream.sendall(payload[:11]); stream.sendall(payload[11:])
                trace.append(runner.next(lambda m: m.get('titles', {}).get('42') == 'Updated synthetic title'))
                geometry = copy.deepcopy(changed)
                geometry['layout']['window_size'] = [600, 300]
                stream.sendall((json.dumps({'WindowOpenedOrChanged': {'window': geometry}}) + '\n').encode())
                trace.append(runner.next(lambda m: m.get('state', {}).get('windows', [{}])[0].get('size') == [600, 300]))
                stream.sendall((json.dumps({'WorkspaceActivated': {'id': 11, 'focused': True}}) + '\n').encode())
                trace.append(runner.next(lambda m: m.get('state', {}).get('windows', [{}])[0].get('hidden') is True))
                events = [
                    {'WindowLayoutsChanged': {'changes': [[42, {'window_size': [300, 200]}]]}},
                    {'KeyboardLayoutsChanged': {'keyboard_layouts': {'names': ['A', 'Б'], 'current_idx': 0}}},
                    {'KeyboardLayoutSwitched': {'idx': 1}},
                    {'OverviewOpenedOrClosed': {'is_open': True}},
                    {'WindowUrgencyChanged': {'id': 42, 'urgent': True}},
                    {'WorkspaceActiveWindowChanged': {'workspace_id': 10, 'active_window_id': 42}},
                    {'FutureSyntheticEvent': {'value': True}},
                ]
                stream.sendall(('\n'.join(json.dumps(x, ensure_ascii=False) for x in events) + '\n').encode())
                trace.append(runner.next(lambda m: m.get('state', {}).get('overview') is True and
                                         m['state']['keyboard']['current_idx'] == 1 and
                                         m['state']['windows'][0].get('is_urgent') is True))
                second = dict(WINDOW, id=43, title='Other synthetic', future_property={'keep': True})
                stream.sendall((json.dumps({'WindowOpenedOrChanged': {'window': second}}) + '\n').encode())
                trace.append(runner.next(lambda m: len(m.get('state', {}).get('windows', [])) == 2))
                stream.sendall((json.dumps({'WindowFocusChanged': {'id': None}}) + '\n').encode())
                trace.append(runner.next(lambda m: len(m.get('state', {}).get('windows', [])) == 2 and
                                         all(not w['is_focused'] for w in m['state']['windows'])))
                stream.sendall((json.dumps({'WindowClosed': {'id': 43}}) + '\n').encode())
                trace.append(runner.next(lambda m: len(m.get('state', {}).get('windows', [])) == 1))
                revised = copy.deepcopy(geometry)
                revised['title'] = 'Final burst'
                revised['layout']['window_size'] = [700, 320]
                intermediate = dict(geometry, title='Intermediate burst')
                burst = [{'WindowOpenedOrChanged': {'window': intermediate}}, {'WindowOpenedOrChanged': {'window': revised}}]
                stream.sendall(('\n'.join(json.dumps(x) for x in burst) + '\n').encode())
                trace.append(runner.next(lambda m: m.get('state', {}).get('windows', [{}])[0].get('size') == [700, 320]))
                self.assertEqual(trace[-1]['state']['windows'][0]['title'], 'Final burst')
                server.outputs['projector'] = {'logical': {'x': -800, 'y': 0, 'width': 800, 'height': 1280,
                                                             'scale': 1.5, 'transform': '90'}}
                stream.sendall((json.dumps({'ConfigLoaded': {}}) + '\n').encode())
                trace.append(runner.next(lambda m: any(x.get('name') == 'projector' for x in m.get('state', {}).get('monitors', []))))
                actions = [{'Action': {'FocusWindow': {'id': 42}}}, {'Action': {'FocusWorkspace': {'reference': {'Id': 11}}}}]
                runner.command(actions)
                self.assertEqual([server.actions.get(timeout=4), server.actions.get(timeout=4)], actions)
                runner.command({'Bad': True})
                self.assertEqual(server.actions.get(timeout=4), {'Bad': True})
                runner.command([{'Bad': True}, {'ShouldNotRun': True}])
                self.assertEqual(server.actions.get(timeout=4), {'Bad': True})
                with self.assertRaises(queue.Empty): server.actions.get(timeout=.15)
                stream.shutdown(socket.SHUT_RDWR)
                runner.next(lambda m: m.get('connected') is False)
                server.streams.get(timeout=6)
                trace.append(runner.next(lambda m: len(m.get('state', {}).get('windows', [])) == 1, timeout=6))
                with self.assertRaises(queue.Empty): server.actions.get(timeout=.15)
                return [{key: value for key, value in message.items() if key != 'bridgeSession'} for message in trace]
            finally:
                runner.close(); server.close()

    def test_same_snapshots_deltas_commands_and_reconnect(self):
        python = self.exercise([sys.executable, '-u', str(ROOT / 'MacShell/niri_ipc.py')])
        rust = self.exercise([RUST])
        self.assertEqual(rust, python)

    def test_replay_geometry_focus_optional_and_future_fields(self):
        outputs = copy.deepcopy(OUTPUTS)
        outputs['rotated'] = {'logical': {'x': -800, 'y': 0, 'width': 800, 'height': 1280,
                                          'scale': 1.5, 'transform': '90'}, 'modes': [], 'current_mode': None}
        outputs['tie'] = {'logical': {'x': 0, 'y': 0, 'width': 1, 'height': 5, 'scale': 2.5}}
        outputs['empty'] = {'logical': {}}
        items = [
            {'outputs': outputs},
            {'event': {'WorkspacesChanged': {'workspaces': WORKSPACES}}},
            {'event': {'WindowsChanged': {'windows': [WINDOW]}}},
            {'event': {'WindowOpenedOrChanged': {'window': dict(WINDOW, title='Renamed')}}},
            {'event': {'WindowOpenedOrChanged': {'window': dict(WINDOW, title=None, future={'x': 1})}}},
            {'event': {'WindowFocusTimestampChanged': {'id': 42, 'focus_timestamp': {'secs': 1, 'nanos': 3}}}},
            {'event': {'WorkspaceUrgencyChanged': {'id': 10, 'urgent': True}}},
            {'event': {'WindowLayoutsChanged': {'changes': [[42, {'window_size': [300, 200]}]]}}},
            {'event': {'WindowLayoutsChanged': {'changes': [[42, {'window_size': [], 'tile_size': [321, 222]}]]}}},
            {'event': {'WorkspaceActivated': {'id': 11, 'focused': False}}},
            {'event': {'WindowFocusChanged': {'id': None}}},
            {'event': {'KeyboardLayoutsChanged': {'keyboard_layouts': {'names': ['English', 'Русский'], 'current_idx': 0}}}},
            {'event': {'KeyboardLayoutSwitched': {'idx': 1}}},
            {'event': {'OverviewOpenedOrClosed': {'is_open': True}}},
            {'event': {'WindowClosed': {'id': 42}}},
            {'event': {'FutureEvent': {'value': 12}}},
        ]
        python = State(); expected = []
        for item in items:
            if 'outputs' in item: python.outputs = copy.deepcopy(item['outputs'])
            change = None
            if 'event' in item:
                outcome = python.apply(copy.deepcopy(item['event']))
                if outcome == 'title':
                    window = item['event']['WindowOpenedOrChanged']['window']
                    change = {'id': str(window['id']), 'title': window.get('title') or ''}
                else: change = 'full'
            expected.append({'change': change, 'state': copy.deepcopy(python.snapshot())})
        input_text = ''.join(json.dumps(item, ensure_ascii=False) + '\n' for item in items)
        result = subprocess.run([RUST, '--replay'], input=input_text, text=True, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        actual = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(len(actual), len(expected))
        for index, (left, right) in enumerate(zip(actual, expected)):
            with self.subTest(step=index): self.assertEqual(left, right)

    def test_rust_discards_command_received_during_retry_wait(self):
        with tempfile.TemporaryDirectory() as directory:
            address = str(Path(directory) / 'fake.sock')
            server = FakeNiri(address); runner = Runner([RUST], address)
            try:
                stream = server.streams.get(timeout=4)
                runner.next(lambda m: len(m.get('state', {}).get('windows', [])) == 1)
                old_session = runner.session
                stream.shutdown(socket.SHUT_RDWR)
                runner.next(lambda m: m.get('connected') is False)
                runner.command({'Action': {'FocusWindow': {'id': 42}}, 'synthetic_padding': 'x' * 12000})
                server.streams.get(timeout=6)
                runner.next(lambda m: len(m.get('state', {}).get('windows', [])) == 1, timeout=6)
                self.assertNotEqual(runner.session, old_session)
                with self.assertRaises(queue.Empty): server.actions.get(timeout=.3)
                runner.command({'Action': {'FocusWindow': {'id': 42}}}, session=old_session)
                with self.assertRaises(queue.Empty): server.actions.get(timeout=.3)
                runner.process.stdin.write(b'{"Action":{"FocusWindow":{"id":42}}}\n')
                runner.process.stdin.flush()
                with self.assertRaises(queue.Empty): server.actions.get(timeout=.3)
                fresh = {'Action': {'FocusWindow': {'id': 42}}}
                runner.command(fresh)
                self.assertEqual(server.actions.get(timeout=3), fresh)
            finally:
                runner.close(); server.close()

    def test_rust_exits_on_stdin_eof_while_disconnected(self):
        with tempfile.TemporaryDirectory() as directory:
            runner = Runner([RUST], str(Path(directory) / 'missing.sock'))
            runner.next(lambda m: m.get('connected') is False)
            started = time.monotonic()
            runner.close()
            self.assertLess(time.monotonic() - started, 2)

    def test_action_never_sent_to_replacement_compositor(self):
        ctx = multiprocessing.get_context('fork')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); old = root / 'old.sock'; new = root / 'new.sock'; current = root / 'current.sock'
            ready = ctx.Queue(); actions = ctx.Queue(); stop = ctx.Event()
            processes = [ctx.Process(target=external_server, args=(str(path), label, ready, actions, stop))
                         for path, label in ((old, 'old'), (new, 'new'))]
            for process in processes: process.start()
            runner = None
            try:
                self.assertEqual({ready.get(timeout=4), ready.get(timeout=4)}, {'old', 'new'})
                current.symlink_to(old)
                runner = Runner([RUST], str(current))
                runner.next(lambda m: len(m.get('state', {}).get('windows', [])) == 1)
                # Let the initial scheduled outputs refresh finish before swapping the socket.
                time.sleep(.3)
                replacement = root / 'replacement.sock'; replacement.symlink_to(new); replacement.replace(current)
                runner.command({'Action': {'FocusWindow': {'id': 42}}})
                self.assertTrue(select.select([runner.process.stderr], [], [], 3)[0], 'No peer mismatch reported')
                self.assertIn(b'different process', os.read(runner.process.stderr.fileno(), 1024))
                with self.assertRaises(queue.Empty): actions.get(timeout=.3)
                # Check that the replacement server itself is reachable and records valid commands.
                with socket.socket(socket.AF_UNIX) as conn:
                    conn.connect(str(current)); conn.sendall(b'{"Control":true}\n'); conn.recv(1024)
                self.assertEqual(actions.get(timeout=3), ('new', {'Control': True}))
            finally:
                if runner is not None: runner.close()
                stop.set()
                for process in processes:
                    process.join(timeout=3)
                    if process.is_alive(): process.terminate(); process.join(timeout=3)
                ready.close(); actions.close()


if __name__ == '__main__': unittest.main()

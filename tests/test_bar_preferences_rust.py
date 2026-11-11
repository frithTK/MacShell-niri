"""Cross-backend menu bar settings checks with temporary files only."""
import concurrent.futures
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / 'MacShell'))
from bar_layout import defaults
from scripts.install_niri import quickshell
from test_system_stats_rust import Client

BINARY = os.environ.get('MACSHELL_TEST_BAR_PREFERENCES_BINARY')


@unittest.skipUnless(BINARY, 'Set MACSHELL_TEST_BAR_PREFERENCES_BINARY to test Rust bar settings')
class BarPreferencesRustTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(); self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.path = self.root / 'macbar/layout.json'

    def start(self, python=False):
        command = [sys.executable, '-u', str(ROOT / 'MacShell/bar_layout_service.py')] if python else [BINARY]
        client = Client(command, env=dict(os.environ, MACSHELL_SETTINGS_HOME=str(self.root)))
        self.addCleanup(client.close)
        client.message(lambda m: m.get('type') == 'ready')
        return client

    def send(self, client, action, data=None, ident=1):
        client.send({'action': action, 'data': data or {}, 'id': ident, 'generation': 8})

    def load(self, client, legacy=None):
        self.send(client, 'load', {'legacy': legacy or {}})
        return client.message(lambda m: m.get('type') == 'state')

    def commit(self, client, values, token, recover=False):
        self.send(client, 'recover' if recover else 'commit', {'values': values, 'token': token}, ident=2)
        state = client.message(lambda m: m.get('type') == 'state')
        result = client.message(lambda m: m.get('type') == 'result')
        return state, result

    def write(self, document):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps(document, ensure_ascii=False))

    def test_legacy_visibility_and_cross_backend_edits(self):
        legacy = {'barWidgets': ['clock', 'volume', 'appleMenu'], 'showTray': False, 'showSearch': False}
        rust = self.start(); python = self.start(python=True)
        state = self.load(rust, legacy); self.assertEqual(state, self.load(python, legacy))
        self.assertEqual([item['type'] for item in state['values']['common'] if item['enabled']], ['appleMenu', 'volume', 'battery', 'clock'])
        self.assertFalse(self.path.exists())
        updated = copy.deepcopy(state['values']); updated['common'][0]['zone'] = 'right'
        after, result = self.commit(rust, updated, state['token'])
        self.assertTrue(result['success']); self.assertTrue(result['changed'])
        self.assertEqual(self.load(python, legacy)['token'], after['token'])
        further = copy.deepcopy(after['values']); further['common'][0]['enabled'] = False
        python_state, result = self.commit(python, further, after['token'])
        self.assertTrue(result['success'])
        self.assertEqual(self.load(rust, legacy)['token'], python_state['token'])
        self.assertFalse(self.commit(rust, python_state['values'], python_state['token'])[1]['changed'])

    def test_loading_existing_documents_matches_python(self):
        rust = self.start(); python = self.start(python=True)
        ordinary = defaults()
        documents = [
            {}, {'common': ordinary['common'], 'future': {'keep': True}},
            {'version': 1, 'revision': 1, 'values': {'common': [False], 'outputs': {}}},
            {'version': 1, 'values': {'common': [], 'outputs': {'bad': {'identity': {'connector': ''}}}}},
            {'version': 1, 'values': {'common': [], 'outputs': {}, 'bindings': {'DP-1': 'missing'}}},
            {'version': 1, 'values': {'common': [{'id': 's', 'type': 'spacer', 'zone': 'left', 'enabled': True, 'priority': 0, 'width': -1}]}},
            {'version': 1, 'revision': True, 'values': {}}, {'version': 1, 'values': []},
            {'version': 2, 'values': ['future'], 'revision': 'different'}, {'version': 99, 'newLayout': []},
        ]
        for document in documents:
            with self.subTest(document=document):
                self.write(document); self.assertEqual(self.load(rust), self.load(python))
        for raw in (b'{broken', b'{"values": NaN}', b'\xff', b'x' * (262144 + 10)):
            with self.subTest(raw=raw[:30]):
                self.path.write_bytes(raw); self.assertEqual(self.load(rust), self.load(python))
        self.path.write_bytes(b'{"version":1,"values":{"common":[{"id":"s","type":"spacer","zone":"left","enabled":true,"priority":-0,"width":-0}]}}')
        self.assertEqual(self.load(rust), self.load(python))
        raw = self.path.read_bytes(); state = self.load(rust)
        self.assertFalse(self.commit(rust, state['values'], state['token'])[1]['changed'])
        self.assertEqual(self.path.read_bytes(), raw)

    def test_profiles_bindings_and_layout_validation_match_python(self):
        rust = self.start(); python = self.start(python=True)
        base = defaults()
        variants = [
            {'outputs': {'one': {'identity': {'connector': 'DP-1'}, 'layout': []}}, 'bindings': {'DP-1': 'one'}},
            {'outputs': {'one': {'identity': {'connector': 'DP-1', 'serial': 1}}}},
            {'outputs': {'one': {'identity': {'connector': 'DP-1', 'make': 'A' * 201}}}},
            {'outputs': {'one': {'identity': {'connector': 'DP-1'}, 'layout': [False]}}},
            {'outputs': {'one': {'identity': {'connector': 'DP-1'}}, 'two': {'identity': {'connector': 'DP-2'}, 'layout': []}},
             'bindings': {'DP-1': 'one'}},
            {'outputs': [], 'bindings': []}, {'outputs': {'': {'identity': {'connector': 'DP-1'}}}},
            {'common': [{'id': 'a', 'type': 'unknown', 'zone': 'left', 'enabled': True},
                        {'id': 'b', 'type': 'unknown', 'zone': 'right', 'enabled': False}]},
            {'common': [{'id': 'x', 'type': 'spacer', 'zone': 'center', 'enabled': True, 'width': 240},
                        {'id': 'y', 'type': 'spacer', 'zone': 'left', 'enabled': False, 'width': 0}]},
        ]
        for change in variants:
            with self.subTest(change=change):
                self.write({'version': 1, 'values': dict(copy.deepcopy(base), **change)})
                self.assertEqual(self.load(rust), self.load(python))

    def test_unknown_blocks_profiles_and_big_numbers_survive(self):
        huge = 10 ** 80 + 99
        values = defaults()
        values['common'] = [{'id': 's', 'type': 'spacer', 'zone': 'left', 'enabled': False, 'priority': 0, 'width': 0},
                            {'id': 'future', 'type': 'future', 'zone': 'right', 'enabled': True, 'priority': 50, 'extension': huge}]
        values['outputs'] = {'screen': {'identity': {'connector': 'DP-1', 'serial': 'one'}, 'layout': [], 'future': huge}}
        values['bindings'] = {'DP-1': 'screen'}
        values['futureRoot'] = {'keep': huge}
        self.write({'version': 1, 'revision': huge, 'extension': huge, 'values': values})
        client = self.start(); state = self.load(client)
        changed = copy.deepcopy(state['values']); changed['common'][0]['enabled'] = True
        after, result = self.commit(client, changed, state['token'])
        self.assertTrue(result['success']); self.assertEqual(after['revision'], huge + 1)
        data = json.loads(self.path.read_text())
        self.assertEqual(data['extension'], huge)
        self.assertEqual(data['values']['futureRoot']['keep'], huge)
        self.assertEqual(data['values']['common'][1]['extension'], huge)
        self.assertEqual(data['values']['outputs']['screen']['future'], huge)

    def test_invalid_layouts_are_rejected_and_manual_conflicts_preserved(self):
        client = self.start(); state = self.load(client); original = defaults()['common']
        invalid = [original + [original[0]], [dict(original[0], id='second'), original[0]],
                   [dict(original[0], zone='bottom')], [dict(original[0], enabled=0)],
                   [dict(original[0], priority=True)], [dict(original[0], priority=101)],
                   [{'id': 's', 'type': 'spacer', 'zone': 'left', 'enabled': True, 'priority': 0, 'width': -1}]]
        for common in invalid:
            with self.subTest(common=common):
                _, result = self.commit(client, dict(defaults(), common=common), state['token'])
                self.assertFalse(result['success']); self.assertFalse(self.path.exists())
        self.write({'version': 1, 'revision': 4, 'values': defaults()})
        state = self.load(client); external = dict(defaults(), common=[])
        self.write({'version': 1, 'revision': 4, 'values': external}); raw = self.path.read_bytes()
        after, result = self.commit(client, defaults(), state['token'])
        self.assertTrue(result['conflict']); self.assertEqual(self.path.read_bytes(), raw)
        self.assertEqual(after['values']['common'], [])

    def test_concurrent_python_and_rust_writers_and_recovery(self):
        rust = self.start(); python = self.start(python=True)
        self.assertEqual(self.load(rust)['token'], 'missing'); self.assertEqual(self.load(python)['token'], 'missing')
        a = dict(defaults(), common=[]); b = defaults(); b['common'][0]['zone'] = 'right'
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            tasks = [pool.submit(self.commit, rust, a, 'missing'), pool.submit(self.commit, python, b, 'missing')]
            results = [task.result() for task in tasks]
        self.assertEqual(sum(result['success'] for _, result in results), 1)
        self.assertEqual(sum(result.get('conflict', False) for _, result in results), 1)
        self.path.write_text('{broken'); raw = self.path.read_bytes(); state = self.load(rust)
        self.assertTrue(state['readOnly']); self.assertTrue(state['canRecover'])
        self.assertFalse(self.commit(rust, defaults(), state['token'])[1]['success'])
        recovered, result = self.commit(rust, defaults(), state['token'], recover=True)
        self.assertTrue(result['success']); self.assertFalse(recovered['readOnly'])
        backups = list(self.path.parent.glob('*.recovery-*.json'))
        self.assertEqual(len(backups), 1); self.assertEqual(backups[0].read_bytes(), raw)

    def test_migration_retains_original_and_future_files_are_read_only(self):
        self.write({'common': defaults()['common'], 'future': {'keep': True}})
        raw = self.path.read_bytes(); client = self.start(); state = self.load(client)
        self.assertTrue(state['migrationPending']); self.assertEqual(self.path.read_bytes(), raw)
        after, result = self.commit(client, state['values'], state['token'])
        self.assertTrue(result['success']); self.assertFalse(after['migrationPending'])
        backups = list(self.path.parent.glob('*.before-v1-*.json'))
        self.assertEqual(len(backups), 1); self.assertEqual(backups[0].read_bytes(), raw)
        self.assertEqual(after['values']['future'], {'keep': True})
        self.write({'version': 99, 'newLayout': []}); future_raw = self.path.read_bytes(); state = self.load(client)
        self.assertTrue(state['readOnly']); self.assertFalse(state['canRecover'])
        self.assertFalse(self.commit(client, defaults(), state['token'], recover=True)[1]['success'])
        self.assertEqual(self.path.read_bytes(), future_raw)

    def test_launcher_prefers_compatible_binary_and_falls_back(self):
        folder = self.root / 'launcher'; folder.mkdir()
        shutil.copy(ROOT / 'MacShell/bar-preferences.sh', folder / 'bar-preferences.sh')
        (folder / 'bar_layout_service.py').write_text('print("legacy")\n')
        binary = folder / 'bar-preferences-rust'
        binary.write_text('#!/bin/sh\nif [ "${1-}" = --protocol-version ]; then echo "macshell-bar-preferences 1"; else echo rust; fi\n')
        binary.chmod(0o755)
        def launch(check=True):
            return subprocess.run(['sh', str(folder / 'bar-preferences.sh')], capture_output=True,
                                  text=True, timeout=5, check=check)
        self.assertEqual(launch().stdout.strip(), 'rust')
        binary.write_text('#!/bin/sh\necho incompatible\n')
        incompatible = launch(check=False)
        self.assertNotEqual(incompatible.returncode, 0)
        self.assertNotIn('legacy', incompatible.stdout)
        self.assertIn('Rust', incompatible.stderr)
        binary.unlink()
        missing = launch(check=False)
        self.assertNotEqual(missing.returncode, 0)
        self.assertNotIn('legacy', missing.stdout)

    @unittest.skipUnless(shutil.which(quickshell()), 'Quickshell is required')
    def test_qml_saves_using_rust_service(self):
        shell = self.root / 'shell'; shutil.copytree(ROOT / 'MacShell', shell)
        shutil.copy(ROOT / 'tests/bar-preferences-rust.qml', shell / 'shell.qml')
        shutil.copy(BINARY, shell / 'bar-preferences-rust')
        (shell / 'bar_layout_service.py').write_text('raise SystemExit("unexpected Python fallback")\n')
        for name in ('runtime', 'config', 'cache'): (self.root / name).mkdir()
        (self.root / 'runtime').chmod(0o700)
        env = dict(os.environ, MACSHELL_SETTINGS_HOME=str(self.root), XDG_RUNTIME_DIR=str(self.root / 'runtime'),
                   XDG_CONFIG_HOME=str(self.root / 'config'), XDG_CACHE_HOME=str(self.root / 'cache'),
                   QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='', QT_QUICK_BACKEND='software',
                   DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(self.root / 'no-bus'))
        env.pop('DISPLAY', None); env.pop('WAYLAND_DISPLAY', None)
        result = subprocess.run([quickshell(), '-p', str(shell)], env=env, capture_output=True, text=True, timeout=16)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('BAR_RUST_QML_PASS', result.stdout + result.stderr)
        self.assertFalse(next(item for item in json.loads(self.path.read_text())['values']['common'] if item['type'] == 'clock')['enabled'])


if __name__ == '__main__': unittest.main()

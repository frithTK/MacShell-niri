"""Cross-version and transactional tests against temporary Activity settings."""
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
from scripts.install_niri import quickshell
from test_system_stats_rust import Client

BINARY = os.environ.get('MACSHELL_TEST_ACTIVITY_PREFERENCES_BINARY')
FIELDS = json.loads((ROOT / 'MacShell/activity_preferences_schema.json').read_text())['fields']
DEFAULTS = {field['key']: field['default'] for field in FIELDS}


@unittest.skipUnless(BINARY, 'Set MACSHELL_TEST_ACTIVITY_PREFERENCES_BINARY to test Rust preferences')
class ActivityPreferencesRustTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(); self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.path = self.root / 'macbar/activity-appearance.json'

    def start(self, python=False):
        command = [sys.executable, '-u', str(ROOT / 'MacShell/activity_preferences_service.py')] if python else [BINARY]
        client = Client(command, env=dict(os.environ, MACSHELL_SETTINGS_HOME=str(self.root)))
        self.addCleanup(client.close)
        client.message(lambda m: m.get('type') == 'ready')
        return client

    def send(self, client, action, data=None, ident=1):
        client.send({'action': action, 'data': data or {}, 'id': ident, 'generation': 8})

    def load(self, client):
        self.send(client, 'load')
        return client.message(lambda m: m.get('type') == 'state')

    def commit(self, client, values, token, recover=False):
        self.send(client, 'recover' if recover else 'commit', {'values': values, 'token': token}, ident=2)
        state = client.message(lambda m: m.get('type') == 'state')
        result = client.message(lambda m: m.get('type') == 'result')
        return state, result

    def write(self, document):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps(document, ensure_ascii=False))

    def test_launcher_prefers_compatible_binary_and_falls_back(self):
        folder = self.root / 'launcher'; folder.mkdir()
        shutil.copy(ROOT / 'MacShell/activity-preferences.sh', folder / 'activity-preferences.sh')
        (folder / 'activity_preferences_service.py').write_text('print("legacy")\n')
        binary = folder / 'activity-preferences-rust'
        binary.write_text('#!/bin/sh\nif [ "${1-}" = --protocol-version ]; then echo "macshell-activity-preferences 1"; else echo rust; fi\n')
        binary.chmod(0o755)
        def launch(check=True):
            return subprocess.run(['sh', str(folder / 'activity-preferences.sh')], capture_output=True,
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

    def test_cross_backend_edits_keep_unknown_fields_and_tokens(self):
        values = dict(copy.deepcopy(DEFAULTS), futureValue={'keep': False})
        self.write({'version': 1, 'revision': 5, 'futureRoot': [1, 2], 'values': values})
        rust = self.start(); python = self.start(python=True)
        first = self.load(rust); baseline = self.load(python)
        for key in ('values', 'token', 'revision', 'readOnly', 'fields'):
            self.assertEqual(first[key], baseline[key], key)
        updated = dict(values, cpuWarning=50)
        after, result = self.commit(rust, updated, first['token'])
        self.assertTrue(result['success']); self.assertTrue(result['changed'])
        self.assertEqual(after['revision'], 6)
        document = json.loads(self.path.read_text())
        self.assertEqual(document['futureRoot'], [1, 2])
        self.assertEqual(document['values']['futureValue'], {'keep': False})
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.load(python)['token'], after['token'])
        python_state, result = self.commit(python, dict(updated, cpuWarning=45), after['token'])
        self.assertTrue(result['success'])
        self.assertEqual(self.load(rust)['token'], python_state['token'])
        self.assertEqual(json.loads(self.path.read_text())['values']['futureValue'], {'keep': False})
        modified = self.path.stat().st_mtime_ns
        _, result = self.commit(rust, python_state['values'], python_state['token'])
        self.assertTrue(result['success']); self.assertFalse(result['changed'])
        self.assertEqual(self.path.stat().st_mtime_ns, modified)

    def test_loading_existing_documents_matches_python(self):
        rust = self.start(); python = self.start(python=True)
        documents = [
            {}, {'cpuWarning': 40, 'future': {'n': 1}},
            {'version': 0, 'values': {'palette': 'monochrome'}},
            {'version': 1, 'revision': 4, 'values': {'cpuWarning': 95, 'cpuCritical': 50}},
            {'version': 1, 'revision': -1, 'values': {}}, {'version': 1, 'values': []},
            {'version': 1, 'revision': True, 'values': {}}, {'version': 1},
            {'version': 2, 'values': ['future'], 'revision': 'different'},
            {'version': 99, 'appearance': {'future': True}},
            {'version': 1.0, 'values': {}}, {'version': -1, 'values': {}},
        ]
        for document in documents:
            with self.subTest(document=document):
                self.write(document)
                a, b = self.load(rust), self.load(python)
                self.assertEqual(a, b)
        for raw in (b'{broken', b'{"values": NaN}', b'\xff', b'x' * (262144 + 10)):
            with self.subTest(raw=raw[:30]):
                self.path.write_bytes(raw)
                self.assertEqual(self.load(rust), self.load(python))

    def test_large_unknown_numbers_and_revision_are_not_rounded(self):
        huge = 10 ** 80 + 123456789
        values = dict(copy.deepcopy(DEFAULTS), futureValue={'large': huge})
        self.write({'version': 1, 'revision': huge, 'futureRoot': huge, 'values': values})
        rust = self.start(); python = self.start(python=True)
        state = self.load(rust)
        self.assertEqual(state, self.load(python))
        self.assertEqual(state['revision'], huge)
        after, result = self.commit(rust, dict(values, cpuWarning=42), state['token'])
        self.assertTrue(result['success']); self.assertEqual(after['revision'], huge + 1)
        document = json.loads(self.path.read_text())
        self.assertEqual(document['revision'], huge + 1)
        self.assertEqual(document['futureRoot'], huge)
        self.assertEqual(document['values']['futureValue']['large'], huge)
        self.assertEqual(self.load(python)['token'], after['token'])
        self.write({'version': 10 ** 400, 'values': {'future': True}})
        future = self.load(rust)
        self.assertTrue(future['readOnly']); self.assertFalse(future['canRecover'])
        self.assertIn('newer MacShell', future['notice'])

    def test_migration_backs_up_exact_input_once(self):
        self.write({'cpuWarning': 40, 'futureValue': {'keep': 0}})
        original = self.path.read_bytes(); client = self.start()
        state = self.load(client); self.assertTrue(state['migrationPending'])
        self.assertEqual(self.path.read_bytes(), original)
        after, result = self.commit(client, state['values'], state['token'])
        self.assertTrue(result['success']); self.assertFalse(after['migrationPending'])
        backups = list(self.path.parent.glob('*.before-v1-*.json'))
        self.assertEqual(len(backups), 1); self.assertEqual(backups[0].read_bytes(), original)
        self.assertEqual(after['values']['futureValue'], {'keep': 0})
        self.assertFalse(self.commit(client, after['values'], after['token'])[1]['changed'])
        self.assertEqual(len(list(self.path.parent.glob('*.before-v1-*.json'))), 1)

    def test_corruption_requires_explicit_recovery_and_future_is_read_only(self):
        client = self.start()
        for document in ({'version': 99, 'revision': 1, 'values': DEFAULTS},
                         {'version': 2, 'appearance': {'style': 'new'}},
                         {'version': 2, 'values': ['future shape'], 'revision': 'new'}):
            self.write(document); original = self.path.read_bytes(); state = self.load(client)
            self.assertTrue(state['readOnly']); self.assertFalse(state['canRecover'])
            self.assertFalse(self.commit(client, DEFAULTS, state['token'], recover=True)[1]['success'])
            self.assertEqual(self.path.read_bytes(), original)
        self.path.write_text('{broken'); original = self.path.read_bytes(); state = self.load(client)
        self.assertTrue(state['readOnly']); self.assertTrue(state['canRecover'])
        self.assertFalse(self.commit(client, DEFAULTS, state['token'])[1]['success'])
        self.assertEqual(self.path.read_bytes(), original)
        recovered, result = self.commit(client, DEFAULTS, state['token'], recover=True)
        self.assertTrue(result['success']); self.assertFalse(recovered['readOnly'])
        backups = list(self.path.parent.glob('*.recovery-*.json'))
        self.assertEqual(len(backups), 1); self.assertEqual(backups[0].read_bytes(), original)

    def test_validation_conflict_and_oversize_are_safe(self):
        client = self.start(); state = self.load(client)
        for patch in ({'cpuWarning': True}, {'cpuWarning': False}, {'cpuWarning': 91}, {'memoryCritical': 10},
                      {'palette': 'neon'}, {'speedUnit': []}, {'order': ['cpu']},
                      {'order': ['cpu', 'cpu', 'network', 'disk']}):
            _, result = self.commit(client, dict(copy.deepcopy(DEFAULTS), **patch), state['token'])
            self.assertFalse(result['success']); self.assertFalse(self.path.exists())
        self.write({'version': 1, 'revision': 4, 'values': DEFAULTS})
        state = self.load(client)
        self.write({'version': 1, 'revision': 4, 'values': dict(DEFAULTS, palette='monochrome')})
        external = self.path.read_bytes()
        updated, result = self.commit(client, dict(DEFAULTS, cpuWarning=25), state['token'])
        self.assertTrue(result['conflict']); self.assertEqual(self.path.read_bytes(), external)
        self.assertEqual(updated['values']['palette'], 'monochrome')
        self.path.write_bytes(b'x' * (262144 + 10)); oversized = self.path.read_bytes()
        state = self.load(client); self.assertTrue(state['readOnly']); self.assertFalse(state['canRecover'])
        self.assertFalse(self.commit(client, DEFAULTS, state['token'], recover=True)[1]['success'])
        self.assertEqual(self.path.read_bytes(), oversized)

    def test_zero_and_threshold_boundaries_survive(self):
        client = self.start(); state = self.load(client)
        values = dict(DEFAULTS, cpuWarning=0, cpuCritical=1, memoryWarning=99, memoryCritical=100)
        after, result = self.commit(client, values, state['token'])
        self.assertTrue(result['success'])
        for key in ('cpuWarning', 'cpuCritical', 'memoryWarning', 'memoryCritical'):
            self.assertEqual(after['values'][key], values[key])

    def test_negative_zero_does_not_cause_a_spurious_write(self):
        self.path.parent.mkdir(parents=True)
        raw = b'{"version":1,"values":{"cpuWarning":-0,"cpuCritical":1}}'
        self.path.write_bytes(raw)
        client = self.start(); state = self.load(client)
        self.assertEqual(state['values']['cpuWarning'], 0)
        self.assertFalse(self.commit(client, state['values'], state['token'])[1]['changed'])
        self.assertEqual(self.path.read_bytes(), raw)

    def test_python_and_rust_concurrent_writers_cannot_lose_a_commit(self):
        rust = self.start(); python = self.start(python=True)
        state1 = self.load(rust); state2 = self.load(python)
        self.assertEqual(state1['token'], 'missing'); self.assertEqual(state2['token'], 'missing')
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            left = pool.submit(self.commit, rust, dict(DEFAULTS, cpuWarning=20), 'missing')
            right = pool.submit(self.commit, python, dict(DEFAULTS, cpuWarning=30), 'missing')
            results = [left.result(), right.result()]
        self.assertEqual(sum(result['success'] for _, result in results), 1)
        self.assertEqual(sum(result.get('conflict', False) for _, result in results), 1)
        self.assertIn(json.loads(self.path.read_text())['values']['cpuWarning'], (20, 30))

    def test_lock_symlink_does_not_modify_target(self):
        client = self.start(); state = self.load(client)
        self.path.parent.mkdir(parents=True)
        target = self.root / 'sentinel'; target.write_bytes(b'keep')
        (self.path.parent / '.activity-appearance.json.lock').symlink_to(target)
        self.send(client, 'commit', {'values': dict(DEFAULTS, cpuWarning=20), 'token': state['token']})
        result = client.message(lambda m: m.get('type') == 'result')
        self.assertFalse(result['success']); self.assertEqual(target.read_bytes(), b'keep')
        self.assertFalse(self.path.exists())

    @unittest.skipUnless(shutil.which(quickshell()), 'Quickshell is required')
    def test_qml_saves_using_rust_service(self):
        shell = self.root / 'shell'; shutil.copytree(ROOT / 'MacShell', shell)
        shutil.copy(ROOT / 'tests/activity-preferences-rust.qml', shell / 'shell.qml')
        shutil.copy(BINARY, shell / 'activity-preferences-rust')
        (shell / 'activity_preferences_service.py').write_text('raise SystemExit("unexpected Python fallback")\n')
        for name in ('runtime', 'config', 'cache'): (self.root / name).mkdir()
        (self.root / 'runtime').chmod(0o700)
        env = dict(os.environ, MACSHELL_SETTINGS_HOME=str(self.root), XDG_RUNTIME_DIR=str(self.root / 'runtime'),
                   XDG_CONFIG_HOME=str(self.root / 'config'), XDG_CACHE_HOME=str(self.root / 'cache'),
                   QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='', QT_QUICK_BACKEND='software',
                   DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(self.root / 'no-bus'))
        env.pop('DISPLAY', None); env.pop('WAYLAND_DISPLAY', None)
        result = subprocess.run([quickshell(), '-p', str(shell)], env=env, capture_output=True, text=True, timeout=16)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('ACTIVITY_RUST_QML_PASS', result.stdout + result.stderr)
        self.assertEqual(json.loads(self.path.read_text())['values']['cpuWarning'], 42)


if __name__ == '__main__': unittest.main()

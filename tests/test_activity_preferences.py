import concurrent.futures
import copy
import importlib.util
import json
import os
from pathlib import Path
import selectors
import sys
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).parents[1] / 'MacShell'
sys.path.insert(0, str(SOURCE))
spec = importlib.util.spec_from_file_location('activity_preferences', SOURCE / 'activity_preferences.py')
prefs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prefs)


class ActivityPreferencesTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / 'macbar/activity-appearance.json'
        self.store = prefs.Preferences(self.path)

    def write(self, document):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps(document))

    def changed(self, **patches):
        return dict(copy.deepcopy(prefs.DEFAULTS), **patches)

    def test_default_load_and_noop_do_not_write(self):
        state = self.store.load()
        self.assertEqual(state['values'], prefs.DEFAULTS)
        self.assertFalse(self.path.exists())
        self.assertTrue(self.store.commit(state['values'], state['token'])['success'])
        self.assertFalse(self.path.exists())

    def test_atomic_commit_retains_unknown_fields_and_does_not_touch_other_settings(self):
        self.write({'version': 1, 'revision': 5, 'futureRoot': [1, 2], 'values': self.changed(futureValue={'x': False})})
        other = self.path.with_name('settings.json')
        other.write_text('{"statsInterval":5,"statsMetrics":[]}')
        state = self.store.load()
        result = self.store.commit(self.changed(cpuWarning=50), state['token'])
        self.assertTrue(result['success'])
        data = json.loads(self.path.read_text())
        self.assertEqual(data['revision'], 6)
        self.assertEqual(data['futureRoot'], [1, 2])
        self.assertEqual(data['values']['futureValue'], {'x': False})
        self.assertEqual(data['values']['cpuWarning'], 50)
        self.assertEqual(json.loads(other.read_text()), {'statsInterval': 5, 'statsMetrics': []})
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        modified = self.path.stat().st_mtime_ns
        result = self.store.commit(data['values'], result['state']['token'])
        self.assertTrue(result['success'])
        self.assertFalse(result['changed'])
        self.assertEqual(self.path.stat().st_mtime_ns, modified)

    def test_old_format_migrates_once_and_keeps_original(self):
        self.write({'cpuWarning': 40, 'futureValue': {'keep': 0}})
        before = self.path.read_bytes()
        state = self.store.load()
        self.assertTrue(state['migrationPending'])
        self.assertEqual(state['values']['cpuWarning'], 40)
        self.assertEqual(self.path.read_bytes(), before)
        result = self.store.commit(state['values'], state['token'])
        self.assertTrue(result['success'])
        self.assertFalse(result['state']['migrationPending'])
        backups = list(self.path.parent.glob('*.before-v1-*.json'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), before)
        self.assertEqual(result['state']['values']['futureValue'], {'keep': 0})
        self.store.commit(result['state']['values'], result['state']['token'])
        self.assertEqual(len(list(self.path.parent.glob('*.before-v1-*.json'))), 1)

    def test_invalid_values_are_rejected_and_loading_can_repair(self):
        for patches in ({'cpuWarning': True}, {'cpuWarning': 91}, {'memoryCritical': 10}, {'palette': 'neon'},
                        {'order': ['cpu', 'cpu', 'network', 'disk']}, {'order': ['cpu']}, {'speedUnit': []}):
            with self.subTest(patches=patches):
                result = self.store.commit(self.changed(**patches), 'missing')
                self.assertFalse(result['success'])
                self.assertFalse(self.path.exists())
        self.write({'version': 1, 'revision': 2, 'values': {'cpuWarning': 95, 'cpuCritical': 50}})
        state = self.store.load()
        self.assertTrue(state['needsRepair'])
        self.assertEqual(state['values']['cpuWarning'], 65)
        self.assertEqual(state['values']['cpuCritical'], 90)
        result = self.store.commit(state['values'], state['token'])
        self.assertTrue(result['changed'])
        self.assertFalse(result['state']['needsRepair'])

    def test_false_zero_and_threshold_boundaries(self):
        value = self.changed(cpuWarning=0, cpuCritical=1, memoryWarning=99, memoryCritical=100)
        normalized, errors = prefs.normalize(value, strict=True)
        self.assertEqual(errors, {})
        self.assertEqual(normalized['cpuWarning'], 0)
        self.assertNotEqual(prefs.normalize(self.changed(cpuWarning=False), strict=True)[1], {})

    def test_external_edit_without_revision_change_causes_conflict(self):
        self.write({'version': 1, 'revision': 4, 'values': self.changed()})
        state = self.store.load()
        self.write({'version': 1, 'revision': 4, 'values': self.changed(palette='monochrome')})
        edited = self.path.read_bytes()
        result = self.store.commit(self.changed(cpuWarning=25), state['token'])
        self.assertTrue(result['conflict'])
        self.assertEqual(self.path.read_bytes(), edited)
        self.assertEqual(result['state']['values']['palette'], 'monochrome')

    def test_concurrent_editors_cannot_lose_a_commit(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
            results = list(executor.map(lambda number: prefs.Preferences(self.path).commit(self.changed(cpuWarning=number), 'missing'), [20, 30]))
        self.assertEqual(sum(result['success'] for result in results), 1)
        self.assertEqual(sum(result.get('conflict', False) for result in results), 1)
        self.assertIn(self.store.load()['values']['cpuWarning'], (20, 30))

    def test_future_version_and_corrupt_file_are_not_overwritten(self):
        self.write({'version': 99, 'revision': 1, 'values': self.changed()})
        before = self.path.read_bytes()
        state = self.store.load()
        self.assertTrue(state['readOnly'])
        self.assertFalse(state['canRecover'])
        self.assertFalse(self.store.commit(self.changed(cpuWarning=20), state['token'])['success'])
        self.assertFalse(self.store.commit(prefs.DEFAULTS, state['token'], recover=True)['success'])
        self.assertEqual(self.path.read_bytes(), before)
        self.path.write_text('{broken')
        before = self.path.read_bytes()
        state = self.store.load()
        self.assertTrue(state['readOnly'])
        self.assertTrue(state['canRecover'])
        self.assertFalse(self.store.commit(prefs.DEFAULTS, state['token'])['success'])
        self.assertEqual(self.path.read_bytes(), before)
        result = self.store.commit(prefs.DEFAULTS, state['token'], recover=True)
        self.assertTrue(result['success'])
        backups = list(self.path.parent.glob('*.recovery-*.json'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), before)
        self.assertFalse(result['state']['readOnly'])

    def test_future_document_shape_cannot_be_recovered_as_corrupt(self):
        for document in ({'version': 2, 'appearance': {'style': 'new'}},
                         {'version': 2, 'values': ['new layout'], 'revision': 'new revision'}):
            with self.subTest(document=document):
                self.write(document)
                before = self.path.read_bytes()
                state = self.store.load()
                self.assertTrue(state['readOnly'])
                self.assertFalse(state['canRecover'])
                self.assertIn('newer MacShell', state['notice'])
                self.assertFalse(self.store.commit(prefs.DEFAULTS, state['token'], recover=True)['success'])
                self.assertEqual(self.path.read_bytes(), before)

    def test_interrupted_replace_keeps_the_original_and_cleans_staging(self):
        self.write({'version': 1, 'values': self.changed()})
        before = self.path.read_bytes()
        state = self.store.load()
        original_replace = os.replace
        def fail_replace(source, destination):
            if destination == self.path:
                raise OSError('simulated interrupted write')
            return original_replace(source, destination)
        with patch.object(prefs.os, 'replace', side_effect=fail_replace):
            with self.assertRaises(OSError):
                self.store.commit(self.changed(cpuWarning=25), state['token'])
        self.assertEqual(self.path.read_bytes(), before)
        self.assertFalse(list(self.path.parent.glob('.activity-appearance.json-*')))

    def test_oversized_or_unreadable_file_does_not_offer_unsafe_recovery(self):
        self.write({'payload': 'x' * prefs.LIMIT})
        state = self.store.load()
        self.assertTrue(state['readOnly'])
        self.assertFalse(state['canRecover'])
        self.assertIn('backup', state['notice'])
        with patch.object(Path, 'open', side_effect=PermissionError('denied')):
            state = self.store.load()
        self.assertTrue(state['readOnly'])
        self.assertFalse(state['canRecover'])

    def test_protocol_generation_state_and_cas(self):
        environment = dict(os.environ, MACSHELL_SETTINGS_HOME=self.temporary.name)
        process = subprocess.Popen(['python3', '-u', str(SOURCE / 'activity_preferences_service.py')],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   env=environment, bufsize=0)
        self.addCleanup(lambda: process.kill() if process.poll() is None else None)
        selector = selectors.DefaultSelector()
        self.addCleanup(selector.close)
        selector.register(process.stdout, selectors.EVENT_READ)
        buffer = b''
        def receive():
            nonlocal buffer
            deadline = time.monotonic() + 4
            while b'\n' not in buffer:
                self.assertTrue(selector.select(max(0, deadline - time.monotonic())), 'Preferences helper timed out')
                data = os.read(process.stdout.fileno(), 65536)
                self.assertTrue(data, 'Preferences helper exited before its response')
                buffer += data
            line, buffer = buffer.split(b'\n', 1)
            return json.loads(line)
        def send(action, data, number):
            process.stdin.write((json.dumps(dict(action=action, data=data, id=number, generation=8)) + '\n').encode())
            process.stdin.flush()
        self.assertEqual(receive()['type'], 'ready')
        send('load', {}, 1)
        state = receive()
        self.assertEqual(state['generation'], 8)
        self.assertEqual(len(state['fields']), len(prefs.FIELDS))
        send('commit', dict(values=self.changed(cpuWarning=55), token=state['token']), 2)
        applied = receive()
        result = receive()
        self.assertEqual(applied['values']['cpuWarning'], 55)
        self.assertTrue(result['success'])
        self.assertEqual(result['id'], 2)
        process.stdin.close()
        self.assertEqual(process.wait(timeout=4), 0)
        process.stdout.close(); process.stderr.close()

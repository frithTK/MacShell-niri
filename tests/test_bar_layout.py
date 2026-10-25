import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest

SOURCE = Path(__file__).parents[1] / 'MacShell'
sys.path.insert(0, str(SOURCE))
from bar_layout import Preferences, defaults, normalize


class BarLayoutTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / 'layout.json'
        self.store = Preferences(self.path)

    def test_legacy_visibility_is_migrated_in_the_actual_visual_order(self):
        legacy = {'barWidgets': ['clock', 'volume', 'appleMenu'], 'showTray': False, 'showSearch': False}
        store = Preferences(self.path, legacy)
        state = store.load()
        common = state['values']['common']
        self.assertEqual([item['type'] for item in common[:4]], ['appleMenu', 'appMenus', 'workspaces', 'monitoring'])
        self.assertEqual([item['type'] for item in common if item['enabled']], ['appleMenu', 'volume', 'battery', 'clock'])
        self.assertFalse(self.path.exists())
        self.assertFalse(next(item for item in defaults({'ccEnabled': False})['common'] if item['type'] == 'privacy')['enabled'])
        changed = copy.deepcopy(state['values'])
        changed['common'][0]['zone'] = 'right'
        result = store.commit(changed, state['token'])
        self.assertTrue(result['success'])
        self.assertEqual(len(store.load()['values']['common']), 15)
        self.assertFalse(store.commit(changed, result['state']['token'])['changed'])

    def test_false_zero_empty_layout_and_unknown_blocks_survive(self):
        value = defaults()
        value['common'] = [{'id': 'spacer-1', 'type': 'spacer', 'zone': 'left', 'enabled': False, 'priority': 0, 'width': 0},
                           {'id': 'future-1', 'type': 'future', 'zone': 'right', 'enabled': True, 'priority': 50, 'future': {'keep': 0}}]
        value['outputs'] = {'screen': {'identity': {'connector': 'DP-1', 'serial': 'one'}, 'layout': [], 'future': True}}
        value['futureRoot'] = {'keep': False}
        result = self.store.commit(value, 'missing')
        self.assertTrue(result['success'])
        self.assertEqual(result['state']['values']['common'], value['common'])
        self.assertEqual(result['state']['values']['outputs'], value['outputs'])
        # Unknown stored values are retained through later edits.
        data = json.loads(self.path.read_text())
        data['values']['futureRoot'] = value['futureRoot']
        self.path.write_text(json.dumps(data))
        state = self.store.load()
        changed = copy.deepcopy(state['values']); changed['common'][0]['enabled'] = True
        result = self.store.commit(changed, state['token'])
        self.assertEqual(result['state']['values']['futureRoot'], value['futureRoot'])

    def test_invalid_singletons_ids_zones_and_ranges_cannot_be_saved(self):
        original = defaults()['common']
        bad = [original + [original[0]], [dict(original[0], id='second'), original[0]],
               [dict(original[0], zone='bottom')], [dict(original[0], enabled=0)],
               [dict(original[0], priority=True)], [dict(original[0], priority=101)],
               [{'id': 's', 'type': 'spacer', 'zone': 'left', 'enabled': True, 'priority': 0, 'width': -1}]]
        for common in bad:
            with self.subTest(common=common):
                result = self.store.commit(dict(defaults(), common=common), 'missing')
                self.assertFalse(result['success'])
                self.assertFalse(self.path.exists())

    def test_inherit_removes_override_and_preserves_disconnected_profiles(self):
        value = defaults()
        value['outputs'] = {
            'one': {'identity': {'connector': 'DP-1', 'make': 'Demo', 'model': 'Display', 'serial': 'one'}, 'layout': []},
            'two': {'identity': {'connector': 'DP-2', 'make': 'Demo', 'model': 'Display', 'serial': 'two'}, 'layout': []}}
        value['bindings'] = {'DP-1': 'one'}
        result = self.store.commit(value, 'missing')
        changed = copy.deepcopy(result['state']['values']); del changed['outputs']['one']['layout']
        result = self.store.commit(changed, result['state']['token'])
        self.assertTrue(result['success'])
        self.assertNotIn('layout', result['state']['values']['outputs']['one'])
        self.assertEqual(result['state']['values']['outputs']['two'], value['outputs']['two'])

    def test_two_drafts_cannot_overwrite_each_other(self):
        value = defaults(); value['common'] = []
        first = self.store.commit(value, 'missing')
        second = self.store.commit(defaults(), 'missing')
        self.assertTrue(first['success']); self.assertTrue(second['conflict'])
        self.assertEqual(self.store.load()['values']['common'], [])

    def test_invalid_saved_layout_is_previewed_without_automatic_repair(self):
        self.path.write_text(json.dumps({'version': 1, 'values': {'common': [False], 'outputs': {}}}))
        before = self.path.read_bytes(); state = self.store.load()
        self.assertTrue(state['needsRepair']); self.assertEqual(state['values']['common'], defaults()['common'])
        self.assertEqual(self.path.read_bytes(), before)
        result = self.store.commit(state['values'], state['token'])
        self.assertTrue(result['success']); self.assertFalse(result['state']['needsRepair'])

    def test_identity_and_explicit_bindings_are_validated(self):
        for value in [dict(defaults(), outputs={'bad': {'identity': {'connector': ''}}}),
                      dict(defaults(), bindings={'DP-1': 'missing'}),
                      dict(defaults(), outputs={'bad': {'identity': {'connector': 'DP-1', 'serial': 1}}})]:
            self.assertTrue(normalize(value, strict=True)[1])

    def test_future_layout_remains_readonly_with_a_different_shape(self):
        self.path.write_text('{"version":99,"newLayout":[]}')
        before = self.path.read_bytes(); state = self.store.load()
        self.assertTrue(state['readOnly']); self.assertFalse(state['canRecover'])
        self.assertFalse(self.store.commit(defaults(), state['token'], recover=True)['success'])
        self.assertEqual(self.path.read_bytes(), before)

import copy
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1] / 'MacShell'))
from widget_layout import Preferences, defaults, migrate, normalize
from widget_layout_service import settings_path

ORIGIN = {'name': 'DP-1', 'make': 'Demo', 'model': 'Display', 'serial': 'one', 'width': 1920, 'height': 1080}


class WidgetLayoutTests(unittest.TestCase):
    def test_image_path_rejects_network_and_survives_storage(self):
        values = migrate(self.legacy(), ORIGIN)
        item = values['widgets'][0]
        item.update(type='image', settings={'image': {'path': '/tmp/photo.png', 'future': False}})
        self.assertFalse(normalize(values, strict=True)[1])
        state = self.save_legacy()
        self.assertTrue(self.store.commit(values, state['token'])['success'])
        self.assertEqual(self.store.load()['values']['widgets'][0], item)
        for options in ({}, {'path': ''}, {'path': '/home/user/Pictures/a.jpg'}):
            item['settings']['image'] = options
            self.assertFalse(normalize(values, strict=True)[1], options)
        for options in (None, [], {'path': 'https://example.com/a.png'}, {'path': 'http://x'}, {'path': 'ftp://x'},
                        {'path': 'a' * 4097}, {'path': 'bad\npath'}):
            item['settings']['image'] = options
            self.assertIn('widgets', normalize(values, strict=True)[1], options)

    def test_timer_presets_validate_and_survive_storage(self):
        values = migrate(self.legacy(), ORIGIN)
        item = values['widgets'][0]
        item.update(type='timer', settings={'timer': {'presets': [1, 25, 1440], 'future': False}})
        self.assertFalse(normalize(values, strict=True)[1])
        state = self.save_legacy()
        self.assertTrue(self.store.commit(values, state['token'])['success'])
        self.assertEqual(self.store.load()['values']['widgets'][0], item)
        for invalid in (None, [], {'presets': []}, {'presets': [1, 2, 0]}, {'presets': [1, 2, 1441]},
                        {'presets': [1, 2, True]}, {'presets': [1, 2, 1.5]}, {'presets': '5,15,25'}):
            item['settings']['timer'] = invalid
            self.assertIn('widgets', normalize(values, strict=True)[1], invalid)

    def test_batteries_settings_round_trip_and_validate(self):
        values = migrate(self.legacy(), ORIGIN)
        item = values['widgets'][0]
        item.update(type='batteries')
        chosen = ['laptop', 'bluetooth:AA:BB:CC:DD:EE:01']
        item['settings'] = dict(style='normal', size='large', batteries=dict(mode='selected', devices=chosen, future=False))
        normalized, errors = normalize(values, strict=True)
        self.assertFalse(errors); self.assertEqual(normalized['widgets'][0], item)
        state = self.save_legacy()
        result = self.store.commit(values, state['token'])
        self.assertTrue(result['success'])
        self.assertEqual(self.store.load()['values']['widgets'][0]['settings']['batteries']['devices'], chosen)
        for options in ({}, {'mode': 'selected', 'devices': []}, {'devices': ['bluetooth-path:/org/bluez/hci0/device_1']}):
            item['settings']['batteries'] = options
            self.assertFalse(normalize(values, strict=True)[1])
        for options in (None, [], {'mode': 'other'}, {'devices': 'laptop'}, {'devices': [False]}, {'devices': ['other']},
                        {'devices': ['laptop', 'laptop']}, {'devices': ['bluetooth:aa:bb:cc:dd:ee:01']}, {'devices': ['laptop'] * 17}):
            item['settings']['batteries'] = options
            self.assertIn('widgets', normalize(values, strict=True)[1], options)

    def test_activity_settings_validate_without_losing_extensions(self):
        values = migrate(self.legacy(), ORIGIN)
        item = values['widgets'][0]
        item.update(type='activity')
        item['settings'] = dict(style='normal', size='large', activity=dict(metrics=['disk', 'cpu'], view='graphs', future=False))
        normalized, errors = normalize(values, strict=True)
        self.assertFalse(errors)
        self.assertEqual(normalized['widgets'][0], item)
        for settings in ({}, {'activity': {}}, {'activity': {'metrics': ['network']}}):
            item['settings'] = settings
            self.assertFalse(normalize(values, strict=True)[1])
        for activity in (None, [], {'metrics': []}, {'metrics': ['cpu', 'cpu']}, {'metrics': ['cpu', False]},
                         {'metrics': ['gpu']}, {'metrics': 'cpu'}, {'view': 'unknown'}):
            item['settings'] = {'activity': activity}
            self.assertIn('widgets', normalize(values, strict=True)[1], activity)

    def test_activity_addition_does_not_write_old_layout_on_read(self):
        state = self.save_legacy()
        self.assertTrue(self.store.commit(state['values'], state['token'])['success'])
        before = self.path.read_bytes()
        state = self.store.load()
        self.assertEqual(self.path.read_bytes(), before)
        values = copy.deepcopy(state['values'])
        source = copy.deepcopy(values['widgets'][0])
        source.update(id='activity', type='activity', settings={'activity': {'metrics': ['cpu'], 'view': 'rings'}})
        values['widgets'].append(source)
        result = self.store.commit(values, state['token'])
        self.assertTrue(result['success'])
        self.assertEqual(result['state']['values']['widgets'][:-1], state['values']['widgets'])
        self.assertEqual(self.store.load()['values']['widgets'][-1], source)

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.path = Path(temporary.name) / 'settings.json'
        self.store = Preferences(self.path, ORIGIN)

    def legacy(self):
        return {'tempUnit': 'F', 'locMode': 'city', 'cityName': 'Demo City', 'futureGlobal': False,
                'widgets': [{'id': 'old-' + size, 'type': 'calendar', 'style': 'normal', 'size': size,
                             'mode': 'dark', 'x': 42 + i * 414, 'y': 56, 'custom': {'keep': 0}}
                            for i, size in enumerate(('small', 'medium', 'large'))]}

    def save_legacy(self, value=None):
        self.path.write_text(json.dumps(value or self.legacy()))
        return self.store.load()

    def test_legacy_sizes_modes_ids_globals_and_extension_fields(self):
        state = self.save_legacy()
        before = self.path.read_bytes()
        self.assertTrue(state['migrationPending']); self.assertFalse(state['readOnly'])
        self.assertEqual(self.path.read_bytes(), before)
        values = state['values']
        self.assertEqual(values['defaults']['tempUnit'], 'F')
        self.assertEqual(values['defaults']['cityName'], 'Demo City')
        self.assertIs(values['defaults']['futureGlobal'], False)
        self.assertEqual([item['id'] for item in values['widgets']], ['old-small', 'old-medium', 'old-large'])
        self.assertEqual([item['position']['column'] for item in values['widgets']], [0, 2, 4])
        for item in values['widgets']:
            self.assertEqual(item['version'], 1); self.assertEqual(item['output'], values['desktopOutput'])
            self.assertEqual(item['settings']['mode'], 'dark'); self.assertEqual(item['custom'], {'keep': 0})
        result = self.store.commit(values, state['token'])
        self.assertTrue(result['success']); self.assertFalse(result['state']['migrationPending'])
        self.assertEqual(next(self.path.parent.glob('settings.before-v1-*.json')).read_bytes(), before)
        document = json.loads(self.path.read_text())
        self.assertEqual(document['version'], 1); self.assertEqual(document['revision'], 1)
        self.assertEqual(document['widgets'], self.legacy()['widgets'])  # Original flat data is also retained.

    def test_service_keeps_the_existing_path_even_with_a_custom_xdg_home(self):
        with patch.dict(os.environ, {'XDG_CONFIG_HOME': '/not-the-legacy-path'}, clear=True):
            with patch('widget_layout_service.Path.home', return_value=self.path.parent):
                self.assertEqual(settings_path(), self.path.parent / '.config/macwidgets/settings.json')
        with patch.dict(os.environ, {'MACSHELL_SETTINGS_HOME': str(self.path.parent)}, clear=True):
            self.assertEqual(settings_path(), self.path.parent / 'macwidgets/settings.json')

    def test_migration_is_not_rebound_when_origin_changes_or_disappears(self):
        state = self.save_legacy()
        result = self.store.commit(state['values'], state['token'])
        before = self.path.read_bytes()
        for origin in ({}, dict(ORIGIN, name='HDMI-A-1', serial='other', width=800)):
            self.store.origin = origin
            state = self.store.load()
            self.assertEqual(state['values'], result['state']['values'])
            self.assertFalse(state['migrationPending']); self.assertFalse(state['readOnly'])
            changed = copy.deepcopy(state['values']); changed['defaults']['tempUnit'] = 'C'
            saved = self.store.commit(changed, state['token'])
            self.assertTrue(saved['success'])
            self.assertEqual(saved['state']['values']['widgets'], result['state']['values']['widgets'])
            self.path.write_bytes(before)

    def test_legacy_waits_for_a_real_screen_and_does_not_write_empty_values(self):
        state = self.save_legacy(); before = self.path.read_bytes()
        self.store.origin = {}
        waiting = self.store.load()
        self.assertTrue(waiting['readOnly']); self.assertTrue(waiting['awaitingDisplay'])
        self.assertFalse(waiting['canRecover'])
        self.assertFalse(self.store.commit(waiting['values'], waiting['token'])['success'])
        self.assertEqual(self.path.read_bytes(), before)
        self.store.origin = ORIGIN
        self.assertEqual(self.store.load()['values'], state['values'])

    def test_duplicate_legacy_ids_are_repaired_deterministically_without_losing_records(self):
        value = self.legacy(); value['widgets'][1]['id'] = 'old-small'; value['widgets'][2]['id'] = 7
        first = migrate(value, ORIGIN); second = migrate(value, ORIGIN)
        self.assertEqual(first, second)
        self.assertEqual([item['id'] for item in first['widgets']], ['old-small', 'old-small-2', '7'])
        self.assertEqual(first['widgets'][1]['legacyId'], 'old-small')
        self.assertFalse(normalize(first, strict=True)[1])

    def test_legacy_global_style_is_a_default_and_explicit_instance_style_wins(self):
        value = self.legacy(); value['style'] = 'normal'; del value['widgets'][0]['style']
        value['widgets'][1]['style'] = 'liquid'
        migrated = migrate(value, ORIGIN)
        self.assertEqual(migrated['defaults']['styles']['calendar'], 'normal')
        self.assertEqual(migrated['defaults']['styles']['clock'], 'liquid')
        self.assertEqual(migrated['widgets'][0]['settings']['style'], 'normal')
        self.assertEqual(migrated['widgets'][1]['settings']['style'], 'liquid')

    def test_unknown_types_future_record_versions_and_fields_survive_edits(self):
        value = self.legacy()
        value['widgets'].append({'id': 'unknown', 'type': 'agenda', 'size': 'wide', 'x': -20, 'custom': {'keep': True}})
        state = self.save_legacy(value)
        result = self.store.commit(state['values'], state['token'])
        document = json.loads(self.path.read_text())
        document['values']['widgets'].append({'id': 'future', 'type': 'clock', 'version': 99, 'newShape': [False, 0]})
        document['values']['extension'] = {'keep': 0}
        self.path.write_text(json.dumps(document))
        state = self.store.load(); self.assertFalse(state['readOnly'])
        changed = copy.deepcopy(state['values']); changed['defaults']['cityName'] = 'Another City'
        result = self.store.commit(changed, state['token'])
        self.assertTrue(result['success'])
        self.assertEqual(result['state']['values']['widgets'], state['values']['widgets'])
        self.assertEqual(result['state']['values']['extension'], {'keep': 0})

    def test_unknown_legacy_reserved_fields_are_archived(self):
        value = {'widgets': [{'id': 'future', 'type': 'agenda', 'version': 4, 'output': 'custom', 'position': {'arbitrary': 0}}]}
        record = migrate(value, ORIGIN)['widgets'][0]
        self.assertEqual(record['legacyRecord'], value['widgets'][0])

    def test_invalid_current_records_are_readonly_and_original_is_kept(self):
        valid = migrate(self.legacy(), ORIGIN)
        bad_records = [dict(valid['widgets'][0], position={'column': True, 'row': 0}),
                       dict(valid['widgets'][0], output='missing'), dict(valid['widgets'][0], settings={'style': 'bad'}),
                       dict(valid['widgets'][0], version=0), {'id': 'invalid', 'type': {}}, False]
        for bad in bad_records:
            with self.subTest(record=bad):
                value = copy.deepcopy(valid); value['widgets'].append(bad)
                self.path.write_text(json.dumps({'version': 1, 'values': value}))
                before = self.path.read_bytes(); state = self.store.load()
                self.assertTrue(state['readOnly']); self.assertTrue(state['canRecover'])
                self.assertFalse(self.store.commit(state['values'], state['token'])['success'])
                self.assertEqual(self.path.read_bytes(), before)

    def test_bad_profile_preview_is_safe_and_cannot_be_written(self):
        value = migrate(self.legacy(), ORIGIN)
        value['outputs'][value['desktopOutput']]['identity'] = None
        self.path.write_text(json.dumps({'version': 1, 'values': value}))
        state = self.store.load()
        self.assertTrue(state['readOnly']); self.assertEqual(state['values']['outputs'], {})
        self.assertEqual(state['values']['desktopOutput'], '')
        self.assertEqual(state['values']['widgets'], [])

    def test_two_writers_and_manual_edits_cannot_overwrite_newer_data(self):
        initial = self.save_legacy()
        self.assertTrue(self.store.commit(initial['values'], initial['token'])['success'])
        first = self.store.load(); other = Preferences(self.path, dict(ORIGIN, name='DP-2'))
        changed = copy.deepcopy(first['values']); changed['defaults']['tempUnit'] = 'C'
        self.assertTrue(other.commit(changed, first['token'])['success'])
        self.assertTrue(self.store.commit(first['values'], first['token'])['conflict'])
        state = self.store.load(); self.path.write_text(self.path.read_text() + ' ')
        self.assertTrue(self.store.commit(state['values'], state['token'])['conflict'])

    def test_corrupt_file_requires_explicit_reset_and_has_a_recovery_copy(self):
        self.path.write_bytes(b'{broken')
        state = self.store.load(); self.assertTrue(state['readOnly']); self.assertTrue(state['canRecover'])
        result = self.store.commit(defaults(), state['token'], recover=True)
        self.assertTrue(result['success']); self.assertEqual(result['state']['values']['widgets'], [])
        self.assertEqual(next(self.path.parent.glob('settings.recovery-*.json')).read_bytes(), b'{broken')

    def test_future_document_with_a_different_shape_is_never_reset(self):
        self.path.write_text('{"version":99,"newShape":[]}')
        state = self.store.load(); before = self.path.read_bytes()
        self.assertTrue(state['readOnly']); self.assertFalse(state['canRecover'])
        self.assertFalse(self.store.commit(defaults(), state['token'], recover=True)['success'])
        self.assertEqual(self.path.read_bytes(), before)

    def test_noop_is_quiet_and_atomic_failure_leaves_the_current_file_intact(self):
        self.assertFalse(self.store.commit(defaults(), 'missing')['changed']); self.assertFalse(self.path.exists())
        state = self.save_legacy(); self.assertTrue(self.store.commit(state['values'], state['token'])['success'])
        state = self.store.load(); before = self.path.read_bytes(); mtime = self.path.stat().st_mtime_ns
        self.assertFalse(self.store.commit(state['values'], state['token'])['changed'])
        self.assertEqual(self.path.stat().st_mtime_ns, mtime)
        changed = copy.deepcopy(state['values']); changed['defaults']['cityName'] = 'Updated'
        import preference_store
        original = preference_store.os.replace
        def interrupted(source, target):
            if Path(target) == self.path:
                raise OSError('simulated interrupted replace')
            return original(source, target)
        with patch('preference_store.os.replace', interrupted):
            with self.assertRaises(OSError): self.store.commit(changed, state['token'])
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)

    def test_limits_malformed_legacy_records_and_inherited_settings(self):
        value = migrate(self.legacy(), ORIGIN)
        value['defaults']['mode'] = 'light'; value['widgets'][0]['settings'] = {}
        self.assertFalse(normalize(value, strict=True)[1])
        for bad in [dict(value, widgets=[{}] * 257), dict(value, bindings={'DP-1': 'missing'}),
                    dict(value, defaults={'styles': False}), dict(value, desktopOutput=3)]:
            self.assertTrue(normalize(bad, strict=True)[1])
        self.save_legacy({'widgets': [{'type': {}, 'id': 'bad'}]})
        self.assertTrue(self.store.load()['readOnly'])

    def test_appearance_roundtrip_retains_unknown_fields_and_other_instances(self):
        values = migrate(self.legacy(), ORIGIN)
        look = {'theme': 'light', 'fontFamily': 'Noto Sans', 'textScale': 1.2,
                'density': 'comfortable', 'tint': '#377cc8', 'future': {'preserved': [False, 0]}}
        values['widgets'][0]['settings']['appearance'] = look
        state = self.store.load()
        saved = self.store.commit(values, state['token'])
        self.assertTrue(saved['success'])
        loaded = self.store.load()
        self.assertEqual(loaded['values']['widgets'], values['widgets'])
        before = self.path.read_bytes()
        self.assertFalse(self.store.commit(loaded['values'], loaded['token'])['changed'])
        self.assertEqual(self.path.read_bytes(), before)
        changed = copy.deepcopy(loaded['values'])
        changed['widgets'][0]['settings']['appearance']['theme'] = 'dark'
        result = self.store.commit(changed, loaded['token'])
        self.assertEqual(result['state']['values']['widgets'][1:], values['widgets'][1:])
        self.assertEqual(result['state']['values']['widgets'][0]['settings']['appearance']['future'], look['future'])

    def test_invalid_appearance_is_readonly_and_failed_commit_keeps_file(self):
        values = migrate(self.legacy(), ORIGIN)
        self.assertTrue(self.store.commit(values, self.store.load()['token'])['success'])
        before = self.path.read_bytes()
        for appearance in (False, [], {'theme': 'sepia'}, {'fontFamily': ''}, {'fontFamily': 'a\nfont'},
                           {'fontFamily': 'a' * 101}, {'textScale': True}, {'textScale': 1.21}, {'textScale': .89},
                           {'density': 'unbounded'}, {'tint': 'red'}, {'tint': '#11ff0080'}):
            with self.subTest(appearance=appearance):
                candidate = copy.deepcopy(values)
                candidate['widgets'][0]['settings']['appearance'] = appearance
                result = self.store.commit(candidate, self.store.load()['token'])
                self.assertFalse(result['success']); self.assertEqual(self.path.read_bytes(), before)
                self.path.write_text(json.dumps({'version': 1, 'values': candidate}))
                invalid = self.path.read_bytes(); state = self.store.load()
                self.assertTrue(state['readOnly']); self.assertEqual(self.path.read_bytes(), invalid)
                self.path.write_bytes(before)

    def test_legacy_and_future_appearance_is_not_rewritten_on_read(self):
        values = migrate(self.legacy(), ORIGIN)
        values['widgets'].append({'id': 'future', 'type': 'clock', 'version': 99,
                                  'settings': {'appearance': {'textScale': 5, 'futureTheme': False}}})
        self.path.write_text(json.dumps({'version': 1, 'values': values}))
        before = self.path.read_bytes(); loaded = self.store.load()
        self.assertFalse(loaded['readOnly']); self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(loaded['values']['widgets'], values['widgets'])

    def test_widget_visibility_and_clock_seconds_preserve_old_documents(self):
        values = migrate(self.legacy(), ORIGIN)
        loaded, errors = normalize(values)
        self.assertFalse(errors); self.assertNotIn('enabled', loaded)
        for enabled in (False, True):
            values['enabled'] = enabled
            for mode in ('smooth', 'tick', 'hidden'):
                values['widgets'][0]['settings']['appearance'] = {'secondsMode': mode}
                normalized, errors = normalize(values)
                self.assertFalse(errors); self.assertIs(normalized['enabled'], enabled)
        for bad in (0, 1, None, 'true'):
            values['enabled'] = bad; self.assertTrue(normalize(values)[1])
        values['enabled'] = True; values['widgets'][0]['settings']['appearance']['secondsMode'] = 'fast'
        self.assertTrue(normalize(values)[1])

    def test_visibility_commits_roundtrip_and_does_not_inject_an_old_default(self):
        values = migrate(self.legacy(), ORIGIN)
        self.path.write_text(json.dumps({'version': 1, 'values': values}))
        before = self.path.read_bytes()
        state = self.store.load()
        self.assertNotIn('enabled', state['values'])
        self.assertEqual(self.path.read_bytes(), before)
        for enabled in (False, True):
            candidate = copy.deepcopy(state['values']); candidate['enabled'] = enabled
            result = self.store.commit(candidate, state['token'])
            self.assertTrue(result['success']); self.assertTrue(result['changed'])
            state = result['state']
            self.assertIs(state['values']['enabled'], enabled)
            self.assertIs(json.loads(self.path.read_text())['values']['enabled'], enabled)
            self.assertEqual(state['values']['widgets'], values['widgets'])
        candidate = copy.deepcopy(state['values']); del candidate['enabled']
        result = self.store.commit(candidate, state['token'])
        self.assertTrue(result['success']); self.assertNotIn('enabled', result['state']['values'])


if __name__ == '__main__':
    unittest.main()

"""Versioned desktop instances; migration is bound to the actual legacy screen."""
import copy
import hashlib
import math
import re

from preference_store import LIMIT, PreferenceStore

STYLES = {'weather': ('liquid', 'normal'), 'calendar': ('liquid', 'normal'),
          'clock': ('liquid', 'light', 'dark'), 'player': ('liquid', 'light', 'dark')}
SIZES = ('small', 'medium', 'large')


def valid_appearance(value):
    if not isinstance(value, dict):
        return False
    for key, item in value.items():
        if key == 'theme' and item not in ('auto', 'light', 'dark'):
            return False
        if key == 'fontFamily' and (not isinstance(item, str) or not item.strip() or len(item) > 100 or any(ord(char) < 32 for char in item)):
            return False
        if key == 'textScale' and (type(item) not in (int, float) or not math.isfinite(item) or not .9 <= item <= 1.2):
            return False
        if key == 'density' and item not in ('compact', 'comfortable'):
            return False
        if key == 'tint' and (not isinstance(item, str) or not re.fullmatch(r'#[0-9a-fA-F]{6}', item)):
            return False
        if key == 'secondsMode' and item not in ('smooth', 'tick', 'hidden'):
            return False
    return True


def defaults():
    return {'defaults': {'tempUnit': 'C', 'locMode': 'auto', 'cityName': '',
                         'styles': {kind: 'liquid' for kind in STYLES}, 'mode': 'auto'},
            'desktopOutput': '', 'outputs': {}, 'bindings': {}, 'widgets': []}


def identifier(value, maximum=100):
    return isinstance(value, str) and 0 < len(value) <= maximum


def valid_origin(origin):
    return (isinstance(origin, dict) and identifier(origin.get('name'), 200)
            and all(isinstance(origin.get(key, ''), str) and len(origin.get(key, '')) <= 200 for key in ('make', 'model', 'serial'))
            and all(type(origin.get(key)) in (int, float) and math.isfinite(origin[key]) and 0 < origin[key] <= 100000
                    for key in ('width', 'height')))


def migrate(source, origin):
    result = defaults()
    if not isinstance(source, dict):
        return result
    # Retain old and extension fields as well as their new effective values.
    result.update(copy.deepcopy(source))
    result['defaults'] = copy.deepcopy({key: value for key, value in source.items() if key not in ('widgets', 'version', 'revision', 'values')})
    for key, value in defaults()['defaults'].items():
        result['defaults'].setdefault(key, value)
    if isinstance(source.get('style'), str) and 'styles' not in source:
        result['defaults']['styles'] = {kind: source['style'] if source['style'] in choices else 'liquid' for kind, choices in STYLES.items()}
    records = source.get('widgets', [])
    if not isinstance(records, list) or len(records) > 256:
        result['widgets'] = records
        return result
    if not records:
        result['widgets'] = []
        return result
    if not valid_origin(origin):
        result['widgets'] = []  # Read-only until the legacy screen can be identified.
        return result
    identity = {key: str(origin.get(source_key, '')) for key, source_key in
                (('connector', 'name'), ('make', 'make'), ('model', 'model'), ('serial', 'serial'))}
    profile = 'legacy-' + hashlib.sha256(identity['connector'].encode()).hexdigest()[:16]
    result['desktopOutput'] = profile
    result['outputs'] = {profile: {'identity': identity}}
    result['bindings'] = {identity['connector']: profile}
    columns = max(1, math.floor((origin['width'] - 42 + 28) / 207))
    left = 21 + math.floor(max(0, origin['width'] - 42 - columns * 179 - (columns - 1) * 28) / 2)
    used, migrated = set(), []
    for index, record in enumerate(records):
        if not isinstance(record, dict):
            migrated.append(record)
            continue
        item = copy.deepcopy(record)
        old_id = item.get('id')
        ident = old_id if identifier(old_id) else 'w' + str(index)
        if type(old_id) in (int, float) and math.isfinite(old_id) and old_id:
            ident = str(old_id)
        suffix = 1
        while ident in used:
            suffix += 1
            ident = (str(old_id or 'w' + str(index)))[:80] + '-' + str(suffix)
        if ident != old_id and old_id is not None:
            item['legacyId'] = old_id
        used.add(ident)
        if any(key in record for key in ('version', 'output', 'position', 'settings')):
            item['legacyRecord'] = copy.deepcopy(record)
        item.update(id=ident, version=1, output=profile)
        if isinstance(item.get('type'), str) and item['type'] in STYLES:
            kind = item['type']
            style = item.get('style', result['defaults']['styles'].get(kind, 'liquid')) if isinstance(result['defaults']['styles'], dict) else item.get('style')
            settings = copy.deepcopy(item.get('settings')) if isinstance(item.get('settings'), dict) else {}
            settings.update(style=style if style in STYLES[kind] else 'liquid',
                            size=item.get('size') if item.get('size') in SIZES else 'small',
                            mode=item.get('mode') if item.get('mode') in ('light', 'dark') else 'auto')
            item['settings'] = settings
            def coordinate(key, offset, pitch):
                number = item.get(key, 0)
                number = number if type(number) in (int, float) and math.isfinite(number) else 0
                return max(0, min(4096, math.floor((number - offset) / pitch + .5)))
            item['position'] = {'column': coordinate('x', left, 207), 'row': coordinate('y', 56, 202)}
        migrated.append(item)
    result['widgets'] = migrated
    return result


def normalize(source, strict=False):
    values = copy.deepcopy(source) if isinstance(source, dict) else {}
    baseline, errors = defaults(), {}
    if 'enabled' in values and type(values['enabled']) is not bool:
        errors['enabled'] = 'Widget visibility must be true or false.'
        values['enabled'] = False
    common = values.get('defaults', {})
    if not isinstance(common, dict):
        errors['defaults'] = 'Invalid common widget settings.'
        common = {}
    for key, allowed in (('tempUnit', ('C', 'F')), ('locMode', ('auto', 'city')), ('mode', ('auto', 'light', 'dark'))):
        if common.get(key, baseline['defaults'][key]) not in allowed:
            errors[key] = 'Invalid common widget setting: ' + key
            common[key] = baseline['defaults'][key]
        common.setdefault(key, baseline['defaults'][key])
    if not isinstance(common.get('cityName', ''), str) or len(common.get('cityName', '')) > 200:
        errors['cityName'] = 'City name must be at most 200 characters.'
        common['cityName'] = ''
    common.setdefault('cityName', '')
    styles = common.get('styles', {})
    if not isinstance(styles, dict):
        errors['styles'] = 'Invalid default widget styles.'
        styles = {}
    for kind, choices in STYLES.items():
        if styles.get(kind, 'liquid') not in choices:
            errors['styles'] = 'Unsupported default widget style.'
            styles[kind] = 'liquid'
        styles.setdefault(kind, 'liquid')
    common['styles'] = styles
    values['defaults'] = common
    profiles = values.get('outputs', {})
    if not isinstance(profiles, dict) or len(profiles) > 64:
        errors['outputs'] = 'At most 64 widget display profiles are supported.'
        profiles = {}
    valid_profiles = {}
    for key, profile in profiles.items():
        identity = profile.get('identity') if isinstance(profile, dict) else None
        if (not identifier(key) or not isinstance(identity, dict) or not identifier(identity.get('connector'), 200)
                or any(not isinstance(identity.get(field, ''), str) or len(identity.get(field, '')) > 200 for field in ('make', 'model', 'serial'))):
            errors['outputs'] = 'A widget display profile needs a valid device identity.'
        else:
            valid_profiles[key] = profile
    profiles = valid_profiles
    values['outputs'] = profiles
    bindings = values.get('bindings', {})
    if not isinstance(bindings, dict) or len(bindings) > 64 or any(not identifier(key, 200) or not isinstance(value, str) or value not in profiles for key, value in bindings.items()):
        errors['bindings'] = 'Widget display bindings must refer to saved profiles.'
        bindings = {}
    values['bindings'] = bindings
    desktop = values.get('desktopOutput', '')
    if not isinstance(desktop, str) or desktop and desktop not in profiles:
        errors['desktopOutput'] = 'The desktop must refer to a saved widget display.'
        desktop = ''
    values['desktopOutput'] = desktop
    records = values.get('widgets', [])
    if not isinstance(records, list) or len(records) > 256:
        errors['widgets'] = 'At most 256 widget instances are supported.'
        records = []
    seen, validated = set(), []
    for record in records:
        valid = isinstance(record, dict) and identifier(record.get('id')) and record['id'] not in seen and identifier(record.get('type'))
        version = record.get('version') if valid else None
        valid = valid and type(version) is int and version >= 1
        if valid:
            seen.add(record['id'])
        if valid and version == 1 and record['type'] in STYLES:
            settings, position = record.get('settings', {}), record.get('position')
            output = record.get('output')
            valid = isinstance(output, str) and output in profiles and isinstance(settings, dict) and isinstance(position, dict)
            valid = valid and all(type(position.get(key)) is int and 0 <= position[key] <= 4096 for key in ('column', 'row'))
            valid = valid and settings.get('style', 'liquid') in STYLES[record['type']] and settings.get('size', 'small') in SIZES and settings.get('mode', 'auto') in ('auto', 'light', 'dark')
            valid = valid and valid_appearance(settings.get('appearance', {}))
        if not valid:
            errors['widgets'] = 'Invalid widget instance, duplicate ID, position or settings. Restore a backup or reset widgets.'
            continue
        validated.append(record)
    values['widgets'] = validated
    return values, errors


class Preferences(PreferenceStore):
    version = 1
    label = 'Widget'
    optional_keys = ('enabled',)

    def __init__(self, path, origin=None):
        super().__init__(path)
        self.origin = origin or {}
        self.defaults = defaults()

    def source_values(self, document):
        source = super().source_values(document)
        return migrate(source, self.origin) if document.get('version', 0) == 0 else source

    def normalize(self, source, strict=False):
        return normalize(source, strict)

    def read(self):
        state = super().read()
        source = super().source_values(state['document'])
        waiting = state['document'].get('version', 0) == 0 and isinstance(source, dict) and bool(source.get('widgets')) and not valid_origin(self.origin)
        state['awaitingDisplay'] = waiting
        if waiting and not state['readOnly']:
            state.update(readOnly=True, canRecover=False, notice='Connect a display to bind the existing desktop widgets before editing.')
        elif state['needsRepair'] and not state['readOnly']:
            state.update(readOnly=True, canRecover=state['raw'] is not None and len(state['raw']) <= LIMIT,
                         notice='Some saved widget records are invalid. Restore a backup or reset widgets; the original file will be kept.')
        return state

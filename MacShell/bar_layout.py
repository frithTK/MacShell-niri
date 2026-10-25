"""Layout schema; legacy arrays control visibility, never display order."""
import copy
import json
from pathlib import Path

from preference_store import PreferenceStore

CATALOG = json.loads(Path(__file__).with_name('bar_catalog.json').read_text())['blocks']
BY_TYPE = {block['type']: block for block in CATALOG}
ZONES = ('left', 'center', 'right')


def defaults(legacy=None):
    legacy = legacy or {}
    enabled = legacy.get('barWidgets')
    result = []
    for block in CATALOG:
        kind = block['type']
        if kind == 'spacer':
            continue
        on = kind in enabled if isinstance(enabled, list) and kind not in ('tray', 'search', 'battery') else True
        if kind == 'privacy':
            on = on and legacy.get('ccEnabled', True) is not False and (not isinstance(enabled, list) or 'controlCenter' in enabled)
        if kind in ('tray', 'search'):
            on = legacy.get('showTray' if kind == 'tray' else 'showSearch', True) is not False
        result.append(dict(id=kind, type=kind, zone=block['zone'], enabled=on, priority=block['priority']))
    return {'common': result, 'outputs': {}, 'bindings': {}}


def normalize(source, strict=False, fallback=None):
    fallback = fallback or defaults()
    values = copy.deepcopy(source) if isinstance(source, dict) else {}
    errors = {}

    def layout(items, key, default):
        if not isinstance(items, list) or len(items) > 64:
            errors[key] = 'A layout must contain at most 64 blocks.'
            return copy.deepcopy(default)
        result, ids, types = [], set(), set()
        for item in items:
            valid = isinstance(item, dict)
            ident = item.get('id') if valid else None
            kind = item.get('type') if valid else None
            valid = valid and isinstance(ident, str) and 0 < len(ident) <= 100 and ident not in ids
            valid = valid and isinstance(kind, str) and 0 < len(kind) <= 100
            valid = valid and item.get('zone') in ZONES and type(item.get('enabled')) is bool
            priority = item.get('priority', BY_TYPE.get(kind, {}).get('priority', 50)) if valid else None
            valid = valid and type(priority) is int and 0 <= priority <= 100
            valid = valid and (kind not in BY_TYPE or kind == 'spacer' or kind not in types)
            if not valid:
                errors[key] = 'Block IDs must be unique; singleton blocks cannot be duplicated. Check zone, visibility and priority.'
                if not strict:
                    # Never turn a damaged layout into a silently saved empty one.
                    return copy.deepcopy(default)
                continue
            ids.add(ident); types.add(kind)
            item = copy.deepcopy(item)
            item['priority'] = priority
            if kind == 'spacer':
                width = item.get('width', 16)
                if type(width) is not int or not 0 <= width <= 240:
                    errors[key] = 'Spacer width must be between 0 and 240.'
                    width = 16
                item['width'] = width
            result.append(item)
        return result

    values['common'] = layout(values.get('common', fallback['common']), 'common', fallback['common'])
    outputs = values.get('outputs', {})
    if not isinstance(outputs, dict) or len(outputs) > 64:
        errors['outputs'] = 'At most 64 saved display profiles are supported.'
        outputs = {}
    profiles = {}
    for ident, profile in outputs.items():
        if not isinstance(ident, str) or not 0 < len(ident) <= 100 or not isinstance(profile, dict):
            errors['outputs'] = 'Invalid saved display profile.'
            continue
        identity = profile.get('identity')
        if not isinstance(identity, dict) or not isinstance(identity.get('connector'), str) or not identity['connector'] or any(not isinstance(identity.get(key, ''), str) or len(identity.get(key, '')) > 200 for key in ('connector', 'make', 'model', 'serial')):
            errors['outputs'] = 'A display profile needs a connector and valid device details.'
            continue
        profile = copy.deepcopy(profile)
        if 'layout' in profile:
            profile['layout'] = layout(profile['layout'], ident, values['common'])
        profiles[ident] = profile
    values['outputs'] = profiles
    bindings = values.get('bindings', {})
    if not isinstance(bindings, dict) or len(bindings) > 64 or any(not isinstance(name, str) or not 0 < len(name) <= 200 or not isinstance(ident, str) or ident not in profiles for name, ident in bindings.items()):
        errors['bindings'] = 'Display bindings must refer to saved profiles.'
        bindings = {}
    values['bindings'] = bindings
    return values, errors


class Preferences(PreferenceStore):
    version = 1
    label = 'Menu bar'

    def __init__(self, path, legacy=None):
        super().__init__(path)
        self.defaults = defaults(legacy)

    def normalize(self, source, strict=False):
        return normalize(source, strict, self.defaults)

"""Owned Activity appearance preferences: validation, CAS and atomic storage."""
import copy
import json
import os
from pathlib import Path

SCHEMA = json.loads(Path(__file__).with_name('activity_preferences_schema.json').read_text())
VERSION = SCHEMA['version']
FIELDS = SCHEMA['fields']
DEFAULTS = {field['key']: field['default'] for field in FIELDS}


def normalize(source, strict=False):
    """The same schema and constraints are used for migration and commits."""
    if not isinstance(source, dict):
        source = {}
    values, errors = copy.deepcopy(source), {}
    for field in FIELDS:
        key, kind = field['key'], field['type']
        value = source.get(key, copy.deepcopy(field['default']))
        if kind == 'integer':
            valid = type(value) is int and field['minimum'] <= value <= field['maximum']
        elif kind == 'choice':
            valid = value in [item['value'] for item in field['choices']]
        else:
            allowed = [item['value'] for item in field['choices']]
            valid = isinstance(value, list) and len(value) == len(allowed) and all(type(item) is str for item in value) and set(value) == set(allowed)
        if not valid:
            errors[key] = field['label'] + ' has an invalid value.'
            value = copy.deepcopy(field['default'])
        values[key] = value
    for field in FIELDS:
        other = field.get('lessThan')
        if other and values[field['key']] >= values[other]:
            errors[field['key']] = field['label'] + ' must be below the critical threshold.'
            if not strict:
                values[field['key']] = copy.deepcopy(field['default'])
                values[other] = copy.deepcopy(DEFAULTS[other])
    return values, errors


from preference_store import LIMIT, PreferenceStore, atomic_write, decode


class Preferences(PreferenceStore):
    version = VERSION
    label = 'Activity'
    defaults = DEFAULTS
    normalize = staticmethod(normalize)

"""Validated per-alert audio parameters, independent of system volume."""
import copy
from clock_sound_library import valid_sound_id

DEFAULTS = {'volume': 90, 'fadeMs': 0, 'startMs': 0, 'durationMs': 0, 'repeat': True}
LIMITS = {'volume': 100, 'fadeMs': 60000, 'startMs': 600000, 'durationMs': 600000}


def normalize(options):
    if options is None:
        return dict(DEFAULTS)
    if not isinstance(options, dict):
        raise ValueError('Invalid sound options')
    result = copy.deepcopy(options)
    for name, upper in LIMITS.items():
        value = options.get(name, DEFAULTS[name])
        if type(value) is not int or not 0 <= value <= upper:
            raise ValueError('Invalid sound ' + name)
        result[name] = value
    repeat = options.get('repeat', True)
    if type(repeat) is not bool:
        raise ValueError('Invalid sound repeat')
    result['repeat'] = repeat
    return result


def validate_presets(presets):
    if not isinstance(presets, dict) or len(presets) > 64:
        raise ValueError('Invalid timer sound presets')
    for key, entry in presets.items():
        if (not isinstance(key, str) or not key.isascii() or not key.isdigit() or
                len(key) > 9 or not 1 <= int(key) <= 604800000 or str(int(key)) != key or
                not isinstance(entry, dict) or not valid_sound_id(entry.get('soundId', ''))):
            raise ValueError('Invalid timer sound preset')
        normalize(entry.get('soundOptions'))
    return presets

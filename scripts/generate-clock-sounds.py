#!/usr/bin/env python3
"""Generate the legacy Clock sound groups without changing the defaults."""

import math
import json
from pathlib import Path
import struct
import wave


RATE = 24000
DESTINATION = Path(__file__).resolve().parents[1] / 'MacShell/sounds'
SOUND_GROUPS = {
    'chime': ('Chime', [0, 4, 7, 12], .18, .05),
    'melody': ('Melody', [0, 7, 4, 12, 7], .20, .025),
    'gentle': ('Gentle', [0, 4, 7], .34, .12),
    'urgent': ('Urgent', [0, 7, 0, 7, 0, 7], .12, .035),
}


def render(notes, gap):
    samples = []
    for frequency, duration in notes:
        count = round(duration * RATE)
        for index in range(count):
            t = index / RATE
            fade = min(1.0, t / .012, (duration - t) / .045)
            tone = math.sin(2 * math.pi * frequency * t) + .18 * math.sin(4 * math.pi * frequency * t)
            samples.append(round(10000 * max(0, fade) * tone))
        samples.extend([0] * round(gap * RATE))
    return struct.pack('<' + 'h' * len(samples), *samples)


def main():
    DESTINATION.mkdir(parents=True, exist_ok=True)
    manifest = []
    for category, (label, intervals, duration, gap) in SOUND_GROUPS.items():
        for index in range(10):
            identifier = category + '-' + str(index + 1).zfill(2)
            base = 261.625565 * 2 ** (index / 12)
            notes = [(base * 2 ** (semitones / 12), duration) for semitones in intervals]
            audio = render(notes, gap)
            with wave.open(str(DESTINATION / (identifier + '.wav')), 'wb') as output:
                output.setnchannels(1)
                output.setsampwidth(2)
                output.setframerate(RATE)
                output.writeframes(audio)
            manifest.append({'id': 'builtin-' + identifier, 'name': label + ' ' + str(index + 1),
                             'category': category, 'file': identifier + '.wav',
                             'durationMs': round(len(audio) / (2 * RATE) * 1000)})
    (DESTINATION / 'catalog.json').write_text(json.dumps({'version': 1, 'sounds': manifest}, indent=2) + '\n')


if __name__ == '__main__':
    main()

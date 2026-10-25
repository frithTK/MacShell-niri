"""Owned deterministic worker; deliberately completes cancelled requests late."""
import json
import os
from pathlib import Path
import signal
import sys
import time

directory = Path(os.environ['MACSHELL_WIDGET_TEST_JOBS'])
kind, epoch = sys.argv[1], int(sys.argv[2])
started_path = directory / (kind + '.started.json')
previous = json.loads(started_path.read_text())


def event(name):
    with (directory / 'events.jsonl').open('a') as stream:
        stream.write(json.dumps({'event': name, 'kind': kind, 'epoch': epoch, 'pid': os.getpid()}) + '\n')
    if name == 'started':
        temporary = directory / (kind + '.starting-' + str(os.getpid()))
        temporary.write_text(json.dumps({'epoch': epoch, 'pid': os.getpid()}))
        temporary.replace(started_path)


def response(cancelled=False):
    if kind == 'weather':
        forecast = {'current': {'temperature_2m': 999 if cancelled else 18, 'weather_code': 0, 'is_day': 1, 'time': '2026-10-25T12:00'},
                    'hourly': {'time': ['2026-10-25T12:00'], 'temperature_2m': [18], 'weather_code': [0], 'is_day': [1]},
                    'daily': {'time': ['2026-10-25'], 'temperature_2m_max': [21], 'temperature_2m_min': [13], 'weather_code': [0]}}
        result = {'forecast': forecast, 'latitude': 50, 'longitude': 10, 'place': 'Fixture', 'located': False}
    else:
        result = {'syncedLyrics': '[00:01.00]Cancelled' if cancelled else '[00:01.00]First line\n[00:20.00]Second line'}
    message = {'epoch': epoch, 'success': True, 'result': result}
    temporary = directory / (kind + '.pending-' + str(os.getpid()))
    temporary.write_text(json.dumps(message))
    temporary.replace(directory / (kind + '.json'))
    print(json.dumps(message), flush=True)


def cancelled(number, frame):
    event('cancelled')
    response(True)
    raise SystemExit(0)


signal.signal(signal.SIGTERM, cancelled)
event('started')
# Only the first request completes quickly. Later requests stay alive until
# cancellation, after the QML harness has observed the installed signal handler.
time.sleep(1.2 if previous.get('pid') else .08)
response()
event('finished')

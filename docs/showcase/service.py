"""Deterministic presentation services; never access devices or the network."""
import json
import os
from pathlib import Path
import selectors
import sys

kind = Path(sys.argv[0]).stem


def sample(index):
    import math
    return dict(type='sample', time=index, cpu=round(17 + math.sin(index / 5) * 8 + (18 if 29 < index < 38 else 0), 1),
                memory=dict(used=11274289152 + index * 1000000, total=34359738368, swapUsed=0),
                network=[820000 + math.sin(index / 6) * 630000, 105000 + math.sin(index / 4) * 81000],
                disk=[1900000 + math.sin(index / 7) * 1800000, 580000 + math.cos(index / 6) * 450000],
                interface='wlan0', device='nvme0n1', diskLabel='System drive', temperature=47,
                capacity=dict(free=274000000000, total=512000000000))


if kind == 'widget_fetch':
    mode, epoch = sys.argv[1], int(sys.argv[2])
    if mode == 'weather':
        result = dict(latitude=60, longitude=25, place='Helsinki', located=False,
                      forecast=dict(current=dict(temperature_2m=18, weather_code=1, is_day=1, time='2026-10-25T09:00'),
                                    hourly=dict(time=[f'2026-10-25T{hour:02}:00' for hour in range(9, 16)], temperature_2m=[18, 19, 20, 21, 20, 19, 18], weather_code=[1, 0, 0, 2, 2, 3, 3], is_day=[1] * 7),
                                    daily=dict(time=[f'2026-10-{day}' for day in range(25, 30)], temperature_2m_max=[21, 20, 19, 18, 20], temperature_2m_min=[13, 12, 12, 11, 13], weather_code=[1, 2, 3, 61, 1])))
    else:
        result = dict(syncedLyrics='[00:01.00]A quiet city, a little light\n[01:20.00]Walking home beneath the sky')
    print(json.dumps(dict(epoch=epoch, success=True, result=result)), flush=True)
    raise SystemExit

states = {
    'network_control': dict(available=True, enabled=True, ethernet=False, networks=[dict(id='demo', ssid='Studio Network', signal=92, inUse=True, secure=True, saved=True, known=True, security='WPA2'), dict(id='guest', ssid='Guest Network', signal=67, inUse=False, secure=True, saved=False, known=False, security='WPA2')]),
    'bluetooth_service': dict(available=True, enabled=True, connected=2, adapters=[dict(path='/demo/adapter', enabled=True)], devices=[dict(path='/demo/headphones', name='Studio Headphones', connected=True, paired=True, adapterEnabled=True, blocked=False, battery=86, icon='audio-headset'), dict(path='/demo/keyboard', name='Wireless Keyboard', connected=True, paired=True, adapterEnabled=True, blocked=False, battery=94, icon='input-keyboard')], others=[]),
    'power_control': dict(available=True, busy=False, profile='balanced', profiles=['power-saver', 'balanced', 'performance'], inhibited='', degraded='', gameHold=False),
}
print(json.dumps(dict(type='ready')), flush=True)
if kind == 'system_stats':
    selector = selectors.DefaultSelector()
    selector.register(sys.stdin, selectors.EVENT_READ)
    generation, index, buffer = None, 60, b''
    while True:
        events = selector.select(timeout=1)
        if events:
            data = os.read(sys.stdin.fileno(), 65536)
            if not data:
                break
            buffer += data
            while b'\n' in buffer:
                line, buffer = buffer.split(b'\n', 1)
                request = json.loads(line)
                generation = request['generation']
                for point in range(index - 60, index + 1):
                    print(json.dumps(dict(sample(point), generation=generation)), flush=True)
        elif generation is not None:
            index += 1
            print(json.dumps(dict(sample(index), generation=generation)), flush=True)
    raise SystemExit
for line in sys.stdin:
    request = json.loads(line)
    if kind in states:
        print(json.dumps(dict(states[kind], type='state', generation=request['generation'])), flush=True)
    else:
        print(json.dumps(dict(type='result', success=True, id=request['id'], generation=request['generation'])), flush=True)

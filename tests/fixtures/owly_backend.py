"""Owly JSON fixture. No radio, D-Bus, discovery or network access."""
import json
import os
from pathlib import Path
import signal
import sys
import time


def emit(**event):
    print(json.dumps(event), flush=True)


trace = Path(os.environ['AIRDROP_TEST_TRACE'])
with trace.open('a') as output:
    output.write(json.dumps(dict(pid=os.getpid(), args=sys.argv[1:])) + '\n')
if sys.argv[1:3] == ['doctor', '--json']:
    print(json.dumps(dict(hardware=True, mode=os.environ.get('AIRDROP_TEST_MODE', 'shared'), missing=[])))
    sys.exit(0)
command = sys.argv[2]
if command == 'capabilities':
    emit(event='capabilities', protocol=1)
elif command == 'radio':
    def stop(*_):
        emit(event='radio_stopped')
        sys.exit(0)
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    emit(event='radio_ready', interface='awdl0')
    while True:
        time.sleep(.1)
elif command == 'browse':
    emit(event='device', key='[fe80::2%8]:8770', name='Test iPhone', flags=137)
    emit(event='scan_done')
elif command == 'send':
    if os.environ.get('AIRDROP_TEST_SEND') == 'silent':
        sys.exit(0)
    emit(event='accepted')
    emit(event='progress', sent=40, total=100)
    emit(event='progress', sent=100, total=100)
    emit(event='delivered')
elif command == 'receive':
    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    emit(event='receiver_ready')
    if os.environ.get('AIRDROP_TEST_OFFER'):
        time.sleep(.2)
        emit(event='request', id=1, name='<Test iPhone>', files=[dict(name='photo.jpg', size=4)], urls=[])
        answer = json.loads(sys.stdin.readline())
        accepted = answer.get('id') == 1 and answer.get('accept') is True
        emit(event='answered', id=1, accepted=accepted)
        if accepted:
            folder = Path(sys.argv[sys.argv.index('--dir') + 1])
            path = folder / 'photo.jpg'
            path.write_bytes(b'test')
            emit(event='received', id=1, paths=[str(path)])
    while True:
        time.sleep(.1)

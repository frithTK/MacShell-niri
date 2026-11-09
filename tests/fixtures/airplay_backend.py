"""Isolated Doubletake socket/UxPlay log peers; never capture or advertise."""
import json
import os
from pathlib import Path
import signal
import socket
import sys
import time


signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
trace = Path(os.environ['AIRPLAY_TEST_TRACE'])

if '-help' in sys.argv:
    print('  -fps int')
    if os.environ.get('AIRPLAY_TEST_VOLUME_SUPPORT', '1') == '1':
        print('  -volume-percent int')
    raise SystemExit(0)


def record(**data):
    with trace.open('a') as output:
        output.write(json.dumps(data) + '\n')


record(pid=os.getpid(), program=Path(sys.argv[0]).name, executable=sys.argv[0], arguments=sys.argv[1:])
if Path(sys.argv[0]).name == 'uxplay':
    if os.environ.get('AIRPLAY_TEST_RECEIVER') == 'fail':
        print('Failed to initialize GStreamer sink', flush=True)
        sys.exit(2)
    if os.environ.get('AIRPLAY_TEST_RECEIVER') == 'port-busy':
        print('Error initialising socket 98', flush=True)
        print('register_dnssd: advertised AirPlay service with "Features" code = 0x1234', flush=True)
        sys.exit(2)
    print('Initialized server socket(s)', flush=True)
    time.sleep(.1)
    print('register_dnssd: advertised AirPlay service with "Features" code = 0x1234', flush=True)
    if os.environ.get('AIRPLAY_TEST_RECEIVER') == 'pin':
        time.sleep(.1)
        print('connection request from Test iPhone (iPhone) with deviceID = test', flush=True)
        print('*** CLIENT MUST NOW ENTER PIN = "0042" AS AIRPLAY PASSWORD', flush=True)
        time.sleep(.3)
        print('Begin streaming to GStreamer video pipeline', flush=True)
        time.sleep(.3)
        print('Open connections: 0', flush=True)
    while True:
        time.sleep(.1)

address = sys.argv[sys.argv.index('-socket') + 1]
listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
listener.bind(address)
listener.listen()
stream = None
muted = False
while True:
    connection, _ = listener.accept()
    with connection:
        request = json.loads(connection.makefile('rb').readline())
        record(request=request)
        command = request['cmd']
        error = ''
        if command == 'connect':
            if request.get('pin') == '0042':
                stream['state'] = 'streaming'
            elif request.get('pin'):
                error = 'Incorrect code'
            else:
                stream = dict(device='Living Room', device_ip=request['target'], state='pin_required',
                              has_audio=True, audio_muted=False,
                              credential_kind=os.environ.get('AIRPLAY_TEST_CREDENTIAL', 'pin'))
        elif command == 'disconnect':
            stream = None
        elif command in ('mute', 'unmute') and stream:
            stream['audio_muted'] = command == 'mute'
        response = dict(ok=not error, state=stream['state'] if stream else 'idle', error=error,
                        streams=[stream] if stream else [])
        if command == 'devices':
            response['devices'] = [dict(name='Living Room', model='Apple TV', ip='127.0.0.42', port=7100)]
        connection.sendall(json.dumps(response).encode() + b'\n')

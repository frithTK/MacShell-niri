#!/usr/bin/env python3
"""Check the actual Owly JSON transfer interface in a private network namespace."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import selectors
import socket
import subprocess
import sys
import tempfile
import time


class Peer:
    def __init__(self, command, environment, folder, name):
        self.log = (folder / (name + '.log')).open('w')
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log, env=environment)
        self.reader = selectors.DefaultSelector()
        self.reader.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = b''
        self.events = []

    def wait(self, event, timeout=12):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            while b'\n' in self.buffer:
                line, self.buffer = self.buffer.split(b'\n', 1)
                message = json.loads(line)
                self.events.append(message)
                if message.get('event') == event:
                    return message
            if self.reader.select(.1):
                data = os.read(self.process.stdout.fileno(), 65536)
                if not data:
                    break
                self.buffer += data
        raise RuntimeError('Missing native AirDrop event: ' + event + '; observed: ' + str([item.get('event') for item in self.events]))

    def answer(self, request, accept):
        self.process.stdin.write(json.dumps(dict(id=request, accept=accept)).encode() + b'\n')
        self.process.stdin.flush()

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=3)
        self.reader.close()
        self.process.stdin.close()
        self.process.stdout.close()
        self.log.close()


def inside(binary):
    original = os.environ.get('MACSHELL_AIRDROP_HOST_NETNS')
    if not original or os.readlink('/proc/self/ns/net') == original or len(socket.if_nameindex()) != 1:
        raise RuntimeError('Refusing to alter the host network namespace')
    def ip(*args):
        subprocess.run(['ip', *args], check=True, capture_output=True)
    ip('link', 'set', 'lo', 'up')
    ip('link', 'add', 'msa', 'type', 'veth', 'peer', 'name', 'msb')
    for interface, address in [('msa', 'fe80::1/64'), ('msb', 'fe80::2/64')]:
        ip('link', 'set', 'dev', interface, 'addrgenmode', 'none')
        ip('link', 'set', interface, 'up')
        ip('-6', 'addr', 'add', address, 'dev', interface, 'nodad')
    index = socket.if_nametoindex('msa')
    with tempfile.TemporaryDirectory(prefix='macshell-airdrop-native-') as directory:
        folder = Path(directory)
        environment = dict(os.environ, DBUS_SYSTEM_BUS_ADDRESS='unix:path=' + str(folder / 'no-bus'),
                           DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(folder / 'no-bus'),
                           XDG_STATE_HOME=str(folder / 'state'), TOKIO_WORKER_THREADS='2', RUST_LOG='warn')
        destination = folder / 'received'; destination.mkdir()
        source = folder / 'photo with spaces.txt'; source.write_bytes(b'Native AirDrop regression\n' * 4096)
        receiver = Peer([str(binary), 'macshell', 'receive', '--iface', 'msb', '--name', 'Native receiver', '--dir', str(destination)], environment, folder, 'receiver')
        try:
            receiver.wait('receiver_ready')
            def sender(name):
                return Peer([str(binary), 'macshell', 'send', '--iface', 'msa', '--name', 'Native sender',
                             '--address', f'[fe80::2%{index}]:8771', '--flags', '137', '--', str(source)], environment, folder, name)
            declined = sender('declined')
            try:
                request = receiver.wait('request')
                receiver.answer(request['id'] + 1000, True)
                time.sleep(.2)
                assert not list(destination.iterdir()), 'Stale answer accepted a transfer'
                receiver.answer(request['id'], False)
                declined.wait('declined')
                assert declined.process.wait(timeout=3) == 1
                assert not list(destination.iterdir()), 'Declined transfer wrote a file'
            finally:
                declined.close()
            accepted = sender('accepted')
            try:
                request = receiver.wait('request')
                receiver.answer(request['id'], True)
                received = receiver.wait('received')
                accepted.wait('delivered')
                assert accepted.process.wait(timeout=3) == 0
                assert any(event['event'] == 'progress' for event in accepted.events)
                paths = [Path(path) for path in received['paths']]
                assert len(paths) == 1 and paths[0].is_relative_to(destination)
                assert hashlib.sha256(paths[0].read_bytes()).digest() == hashlib.sha256(source.read_bytes()).digest()
            finally:
                accepted.close()
        finally:
            receiver.close()
        print('AIRDROP_NATIVE_PASS: actual TLS transfer, declined/stale approval, progress, confirmed delivery and matching file hash; host Wi-Fi untouched.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--inside', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.inside:
        inside(args.binary.resolve())
    else:
        subprocess.run(['unshare', '--user', '--map-root-user', '--net', '--', sys.executable, str(Path(__file__).resolve()),
                        '--inside', '--binary', str(args.binary.resolve())], check=True,
                       env=dict(os.environ, MACSHELL_AIRDROP_HOST_NETNS=os.readlink('/proc/self/ns/net')))


if __name__ == '__main__':
    main()

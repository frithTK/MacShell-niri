#!/usr/bin/env python3
"""Optional real UxPlay PIN regression; needs its source, cc and OpenSSL headers."""
import argparse
import ctypes
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import socket
import subprocess
import tempfile
import time


def srp_client(source, folder):
    # Upstream keeps the matching Apple-variant client behind disabled blocks.
    # Enable them only in this temporary test library; retain all source notices.
    for name in ('srp.c', 'srp.h'):
        text = (source / 'lib' / name).read_text()
        text = re.sub(r'#if 0(?=\s*/\*\s*begin removed section)', '#if 1', text)
        (folder / name).write_text(text)
    flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'openssl'], text=True))
    library = folder / 'srp-client.so'
    subprocess.run(['cc', '-shared', '-fPIC', '-O2', str(folder / 'srp.c'), '-o', str(library), *flags], check=True)
    lib = ctypes.CDLL(str(library))
    pointer = ctypes.c_void_p
    output = ctypes.POINTER(pointer)
    integer = ctypes.c_int
    lib.srp_user_new.argtypes = [integer, integer, ctypes.c_char_p, ctypes.c_char_p, integer, pointer, pointer, integer]
    lib.srp_user_new.restype = pointer
    lib.srp_user_start_authentication.argtypes = [pointer, output, output, ctypes.POINTER(integer)]
    lib.srp_user_process_challenge.argtypes = [pointer, ctypes.c_char_p, integer, ctypes.c_char_p, integer, output, ctypes.POINTER(integer)]
    lib.srp_user_verify_session.argtypes = [pointer, ctypes.c_char_p]
    lib.srp_user_is_authenticated.argtypes = [pointer]
    lib.srp_user_is_authenticated.restype = integer
    lib.srp_user_delete.argtypes = [pointer]
    return lib


def free_ports():
    for _ in range(100):
        base = 20000 + secrets.randbelow(30000)
        held = []
        try:
            for port in range(base, base + 3):
                for kind in (socket.SOCK_STREAM, socket.SOCK_DGRAM):
                    probe = socket.socket(socket.AF_INET6, kind)
                    held.append(probe)
                    probe.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
                    probe.bind(('::', port))
            return base
        except OSError:
            pass
        finally:
            for probe in held:
                probe.close()
    raise RuntimeError('No free test port range')


class RTSP:
    def __init__(self, port):
        self.connection = socket.create_connection(('127.0.0.1', port), timeout=3)
        self.reader = self.connection.makefile('rb')
        self.sequence = 0

    def close(self):
        self.reader.close()
        self.connection.close()

    def post(self, path, value=None):
        self.sequence += 1
        data = plistlib.dumps(value, fmt=plistlib.FMT_BINARY) if value is not None else b''
        headers = f'POST {path} RTSP/1.0\r\nCSeq: {self.sequence}\r\nContent-Type: application/x-apple-binary-plist\r\nContent-Length: {len(data)}\r\n\r\n'
        self.connection.sendall(headers.encode() + data)
        status = self.reader.readline()
        if not status:
            raise RuntimeError('UxPlay closed the protocol connection')
        code = int(status.split()[1])
        fields = {}
        while True:
            line = self.reader.readline()
            if line in (b'\r\n', b'\n'):
                break
            if not line:
                raise RuntimeError('Incomplete RTSP header')
            key, value = line.decode().split(':', 1)
            fields[key.lower()] = value.strip()
        body = self.reader.read(int(fields.get('content-length', 0)))
        return code, plistlib.loads(body) if body else {}


def exchange(lib, port, password, proof_size=None):
    peer = RTSP(port)
    user = None
    try:
        assert peer.post('/pair-pin-start')[0] == 200
        code, challenge = peer.post('/pair-setup-pin', dict(method='pin', user='macshell-regression'))
        assert code == 200
        # Expanded upstream enums: SHA1=0; the complete group list has 2048=2.
        user = lib.srp_user_new(0, 2, b'macshell-regression', password, len(password), None, None, 1)
        assert user
        name, public, size = ctypes.c_void_p(), ctypes.c_void_p(), ctypes.c_int()
        lib.srp_user_start_authentication(user, ctypes.byref(name), ctypes.byref(public), ctypes.byref(size))
        public_key = ctypes.string_at(public, size.value)
        proof, length = ctypes.c_void_p(), ctypes.c_int()
        salt, server_key = challenge['salt'], challenge['pk']
        lib.srp_user_process_challenge(user, salt, len(salt), server_key, len(server_key), ctypes.byref(proof), ctypes.byref(length))
        assert length.value == 20, 'Apple SHA1 proof must be 20 bytes'
        data = ctypes.string_at(proof, length.value)
        if proof_size is not None:
            data = (data + bytes(proof_size))[:proof_size]
        code, response = peer.post('/pair-setup-pin', dict(pk=public_key, proof=data))
        if code == 200:
            assert len(response['proof']) == 20
            lib.srp_user_verify_session(user, response['proof'])
            assert lib.srp_user_is_authenticated(user) == 1, 'Incorrect server proof'
        return code
    finally:
        if user:
            lib.srp_user_delete(user)
        peer.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--binary', type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='macshell-uxplay-pin-') as directory:
        folder = Path(directory)
        lib = srp_client(args.source.resolve(), folder)
        port = free_ports()
        pin = f'{secrets.randbelow(10000):04d}'.encode()
        rc = folder / 'uxplayrc'
        rc.touch(mode=0o600)
        log = folder / 'receiver.log'
        with log.open('w') as stream:
            process = subprocess.Popen([str(args.binary.resolve()), '-n', 'MacShell PIN Regression', '-nh', '-m', '02:00:00:00:71:00',
                                        '-pin', pin.decode(), '-key', str(folder / 'receiver.pem'), '-p', str(port),
                                        '-vs', 'fakesink', '-as', 'fakesink'], stdout=stream, stderr=subprocess.STDOUT,
                                       env=dict(os.environ, UXPLAYRC=str(rc), LC_ALL='C'))
            try:
                deadline = time.monotonic() + 10
                while True:
                    try:
                        with socket.create_connection(('127.0.0.1', port + 1), timeout=.2):
                            break
                    except OSError:
                        if process.poll() is not None or time.monotonic() > deadline:
                            raise RuntimeError('Test receiver failed to start')
                        time.sleep(.05)
                correct = exchange(lib, port + 1, pin)
                if correct != 200:
                    diagnostic = re.search(r'Client Authentication Failure \(client_proof_len \d+ invalid\)', log.read_text())
                    raise AssertionError('Correct PIN rejected: RTSP ' + str(correct) + (': ' + diagnostic[0] if diagnostic else ''))
                wrong = bytes((value + 1 - 48) % 10 + 48 for value in pin)
                assert exchange(lib, port + 1, wrong) == 470, 'Wrong PIN accepted'
                for length in (0, 19, 21, 64, 4096):
                    assert exchange(lib, port + 1, pin, length) == 470, 'Malformed proof accepted'
                    assert process.poll() is None, 'Malformed proof crashed UxPlay'
                assert exchange(lib, port + 1, pin) == 200, 'Valid retry failed after rejected proofs'
                print('UXPLAY_PIN_NATIVE_PASS: correct PIN and server proof, wrong PIN, malformed lengths 0/19/21/64/4096 and valid retry.')
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)


if __name__ == '__main__':
    main()

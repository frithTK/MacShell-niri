#!/usr/bin/env python3
"""Start one managed MacShell instance in an existing niri session."""
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys


def check_no_instance(qs):
    result = subprocess.run([qs, '-c', 'MacShell-niri', 'list', '--any-display', '--json'],
                            check=True, capture_output=True, text=True, timeout=5)
    # Quickshell prints this human-readable message, even with --json, when
    # the selected configuration has no live instances.
    if result.stdout.startswith('No running instances for "') and result.stdout.rstrip().endswith('Use --all to list all instances.'):
        return
    instances = json.loads(result.stdout)
    if not isinstance(instances, list):
        raise RuntimeError('Unexpected Quickshell instance list')
    if instances:
        raise RuntimeError('MacShell is already running; refusing to start a second instance')


def start():
    required = ('WAYLAND_DISPLAY', 'NIRI_SOCKET', 'MACSHELL_SESSION_TOKEN')
    if any(not os.environ.get(name) for name in required):
        raise RuntimeError('Missing compositor session environment')
    result = subprocess.run(['systemctl', '--user', 'show', 'niri-macshell.service',
                             '--property=ActiveState', '--value'], check=True,
                            capture_output=True, text=True, timeout=5)
    if result.stdout.strip() not in ('active', 'activating'):
        raise RuntimeError('The MacShell compositor session is not running')
    result = subprocess.run(['systemctl', '--user', 'show', 'niri-macshell.service',
                             '--property=MainPID', '--value'], check=True,
                            capture_output=True, text=True, timeout=5)
    pid = int(result.stdout.strip())
    if pid <= 0:
        raise RuntimeError('The MacShell compositor has no process')
    token = ('MACSHELL_SESSION_TOKEN=' + os.environ['MACSHELL_SESSION_TOKEN']).encode()
    if token not in Path('/proc', str(pid), 'environ').read_bytes().split(b'\0'):
        raise RuntimeError('The compositor belongs to another session')
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(2)
        connection.connect(os.environ['NIRI_SOCKET'])
        peer_pid, peer_uid, _ = struct.unpack('3i', connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
    if peer_pid != pid or peer_uid != os.getuid():
        raise RuntimeError('The niri socket belongs to another compositor')
    names = [name for name in ('WAYLAND_DISPLAY', 'NIRI_SOCKET', 'MACSHELL_SESSION_TOKEN',
                                'XDG_CURRENT_DESKTOP', 'XDG_SESSION_TYPE') if os.environ.get(name)]
    subprocess.run(['systemctl', '--user', 'import-environment', *names], check=True, timeout=5)
    subprocess.run(['systemctl', '--user', 'start', 'macshell-niri-shell.service'], check=True, timeout=15)


if __name__ == '__main__':
    try:
        if len(sys.argv) == 2 and sys.argv[1] == 'start':
            start()
        elif len(sys.argv) == 3 and sys.argv[1] == 'check':
            check_no_instance(sys.argv[2])
        else:
            raise ValueError('Usage: shell_supervisor.py start | check QS_BINARY')
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print('MacShell supervisor:', error, file=sys.stderr)
        sys.exit(1)

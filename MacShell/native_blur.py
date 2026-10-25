#!/usr/bin/env python3
"""Apply niri's real, global blur strength through one owned profile include."""
import json
import math
import os
from pathlib import Path
import re
import socket
import stat
import struct
import subprocess
import tempfile

from line_service import LineService


MARKER = '// Managed by MacShell: native blur strength.\n'
INCLUDE = 'include "./macshell-blur.kdl"'


def blur_config(level):
    level = max(0, min(80, round(float(level))))
    # Keep the pass count fixed to avoid jumps and changes in GPU cost while
    # dragging. Offset 0.5..4 stays within a useful range for three Kawase passes.
    # Zero removes only MacShell's blur regions, never disables other apps' blur.
    offset = .5 + level * 3.5 / 80
    return MARKER + f'// Level: {level}\nblur {{ passes 3; offset {offset:.5f}; }}\n'


def active_profile():
    profile = os.environ.get('MACSHELL_NIRI_PROFILE')
    address = os.environ.get('NIRI_SOCKET')
    if not profile or not address:
        raise RuntimeError('Native blur needs the active MacShell niri profile.')
    config = Path(profile).resolve() / 'config.kdl'
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(2)
        connection.connect(address)
        pid, uid, _ = struct.unpack('3i', connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
    if uid != os.getuid():
        raise RuntimeError('The niri session belongs to another user.')
    args = Path(f'/proc/{pid}/cmdline').read_bytes().decode().rstrip('\0').split('\0')
    current = Path(os.environ.get('XDG_CONFIG_HOME', Path.home() / '.config')) / 'niri/config.kdl'
    for index, arg in enumerate(args):
        if arg in ('--config', '-c') and index + 1 < len(args):
            current = Path(args[index + 1])
        elif arg.startswith('--config='):
            current = Path(arg.split('=', 1)[1])
    if not config.is_file() or current.resolve() != config:
        raise RuntimeError('Native blur needs the active MacShell niri profile.')
    return config


def read_owned(path):
    text = path.read_text() if path.exists() else None
    if text is not None and not text.startswith(MARKER):
        raise RuntimeError('The native blur file was edited outside MacShell; leaving it unchanged.')
    return text


def atomic_write(path, data):
    fd, name = tempfile.mkstemp(prefix='.macshell-blur-', suffix='.tmp', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as file:
            os.fchmod(file.fileno(), stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600)
            file.write(data)
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


def apply_blur(config, level):
    fragment = config.parent / 'macshell-blur.kdl'
    previous = read_owned(fragment)
    before = config.read_bytes()
    # Keep our override last, without editing existing blur, noise, saturation,
    # or the user's explicit `blur { off; }` setting in any other file.
    text = re.sub(r'^include "\./macshell-blur\.kdl"[ \t]*\n?', '', before.decode(), flags=re.MULTILINE)
    text = text.rstrip() + '\n\n' + INCLUDE + '\n'
    contents = blur_config(level)
    if previous == contents and before.decode() == text:
        return
    with tempfile.TemporaryDirectory(prefix='.macshell-blur-', dir=config.parent) as directory:
        directory = Path(directory)
        proposed_fragment = directory / 'blur.kdl'
        proposed_fragment.write_text(contents)
        # The candidate stays beside the active config so relative includes
        # retain their original meaning. Validation never touches the live file.
        fd, candidate_name = tempfile.mkstemp(prefix='.macshell-blur-check-', suffix='.kdl', dir=config.parent)
        candidate = Path(candidate_name)
        try:
            with os.fdopen(fd, 'w') as file:
                file.write(text.replace(INCLUDE, 'include ' + json.dumps(str(proposed_fragment))))
            result = subprocess.run(['niri', 'validate', '-c', str(candidate)], capture_output=True, text=True, timeout=5)
            if result.returncode:
                raise RuntimeError('niri rejected the blur setting; the active configuration was not changed.')
        finally:
            candidate.unlink(missing_ok=True)
        if config.read_bytes() != before or read_owned(fragment) != previous:
            raise RuntimeError('The niri configuration changed while applying blur. Try again.')
        if text.encode() != before:
            backup = config.parent / 'macshell-blur-config.before'
            if not backup.exists():
                backup.write_bytes(before)
        atomic_write(fragment, contents.encode())
        try:
            if text.encode() != before:
                atomic_write(config, text.encode())
        except OSError:
            if previous is None:
                fragment.unlink(missing_ok=True)
            else:
                atomic_write(fragment, previous.encode())
            raise


class NativeBlur(LineService):
    def command(self, request):
        try:
            config = active_profile()
            if request['action'] == 'apply':
                level = float(request.get('data', {}).get('level', 5))
                if not math.isfinite(level):
                    raise ValueError('Invalid blur strength.')
                apply_blur(config, level)
            text = read_owned(config.parent / 'macshell-blur.kdl')
            match = re.search(r'^// Level: (\d+)$', text or '', re.MULTILINE)
            self.emit(type='state', available=True, managed=bool(match), level=int(match[1]) if match else -1, error='')
        except (ValueError, RuntimeError) as error:
            self.emit(type='state', available=False, managed=False, level=-1, error=str(error))
        except (OSError, subprocess.SubprocessError):
            self.emit(type='state', available=False, managed=False, level=-1,
                      error='Could not apply native blur. Check that the MacShell niri profile is active and valid.')

    def wait_timeout(self):
        return None


if __name__ == '__main__':
    NativeBlur().run()

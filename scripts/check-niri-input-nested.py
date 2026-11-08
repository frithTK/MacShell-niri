#!/usr/bin/env python3
"""Inspect include reload using keyboard layouts in an isolated nested niri."""
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import time
import uuid


def child(root, parent_display, parent_socket):
    root = Path(root)
    address = os.environ.get("NIRI_SOCKET", "")
    display = os.environ.get("WAYLAND_DISPLAY", "")
    if not address or address == parent_socket or not display or display == parent_display:
        raise RuntimeError("Refusing non-isolated compositor")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.connect(address)
        pid, uid, _ = struct.unpack("3i", conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
    token = ("MACSHELL_NESTED_TEST_TOKEN=" + os.environ["MACSHELL_NESTED_TEST_TOKEN"]).encode()
    if uid != os.getuid() or token not in Path('/proc', str(pid), 'environ').read_bytes().split(b'\0'):
        raise RuntimeError("Socket does not belong to the test compositor")

    def layouts():
        result = subprocess.run(["niri", "msg", "-j", "keyboard-layouts"],
                                capture_output=True, text=True, check=True, timeout=3)
        return json.loads(result.stdout)["names"]

    try:
        initial = layouts()
        candidate = root / "candidate.kdl"
        candidate.write_text('input { keyboard { xkb { layout "de"; }; }; }\n')
        os.replace(candidate, root / "fragment.kdl")
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            current = layouts()
            if current != initial:
                break
            time.sleep(.1)
        else:
            raise RuntimeError("Timed out waiting for automatic include reload; initial=" + repr(initial))
        (root / "result.json").write_text(json.dumps({"initial": initial, "after": current}))
    finally:
        subprocess.run(["niri", "msg", "action", "quit", "--skip-confirmation"],
                       capture_output=True, timeout=5, check=False)


def main():
    if len(sys.argv) == 5 and sys.argv[1] == "--child":
        try:
            child(*sys.argv[2:])
        except Exception as error:
            (Path(sys.argv[2]) / "error.txt").write_text(repr(error))
            raise
        return
    parent_display = os.environ.get("WAYLAND_DISPLAY", "")
    parent_socket = os.environ.get("NIRI_SOCKET", "")
    if not parent_display or not parent_socket:
        raise RuntimeError("A parent Wayland/niri session is required")
    with tempfile.TemporaryDirectory(prefix="macshell-input-nested-") as directory:
        root = Path(directory)
        (root / "config.kdl").write_text('input { keyboard { xkb { layout "us"; }; }; }\ninclude "./fragment.kdl"\nhotkey-overlay { skip-at-startup; }\n')
        (root / "fragment.kdl").write_text('input { keyboard { xkb { layout "ru"; }; }; }\n')
        env = dict(os.environ, MACSHELL_NESTED_TEST_TOKEN=uuid.uuid4().hex,
                   HOME=directory, XDG_CONFIG_HOME=str(root / "config"),
                   XDG_CACHE_HOME=str(root / "cache"), XDG_STATE_HOME=str(root / "state"),
                   DBUS_SESSION_BUS_ADDRESS="unix:path=" + str(root / "no-bus"),
                   DBUS_SYSTEM_BUS_ADDRESS="unix:path=" + str(root / "no-bus"))
        env.pop("NIRI_SOCKET", None)
        with (root / "niri.log").open("w") as log:
            process = subprocess.Popen(["niri", "-c", str(root / "config.kdl"), "--", sys.executable,
                                        str(Path(__file__).resolve()), "--child", directory,
                                        parent_display, parent_socket], env=env, stdout=log, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline and not (root / "result.json").exists() and not (root / "error.txt").exists() and process.poll() is None:
                    time.sleep(.1)
                if not (root / "result.json").exists():
                    raise RuntimeError((root / "niri.log").read_text()[-8000:])
                print(json.dumps(json.loads((root / "result.json").read_text())))
            finally:
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=5)


if __name__ == "__main__":
    main()

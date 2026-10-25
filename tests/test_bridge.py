"""Exercise the complete persistent bridge against a private IPC peer."""
import json
import os
from pathlib import Path
import queue
import select
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest


class BridgeTests(unittest.TestCase):
    def test_stream_updates_and_commands_use_separate_request_connections(self):
        with tempfile.TemporaryDirectory() as directory:
            address = str(Path(directory) / "niri.sock")
            actions = queue.Queue()
            stream = queue.Queue()
            stop = threading.Event()
            with socket.socket(socket.AF_UNIX) as listener:
                listener.bind(address)
                listener.listen()
                listener.settimeout(.1)
                def handle(connection):
                    with connection:
                        value = json.loads(connection.makefile("rb").readline())
                        if value == "Outputs":
                            reply = {"Ok": {"Outputs": {}}}
                        elif value == "EventStream":
                            connection.sendall(b'{"Ok":"Handled"}\n')
                            events = [
                                {"WorkspacesChanged": {"workspaces": []}},
                                {"WindowsChanged": {"windows": [{"id": 42, "app_id": "test", "title": "First", "layout": {}}]}},
                            ]
                            for event in events:
                                connection.sendall((json.dumps(event) + "\n").encode())
                            stream.put(connection)
                            stop.wait(5)
                            return
                        else:
                            actions.put(value)
                            reply = {"Ok": "Handled"}
                        connection.sendall((json.dumps(reply) + "\n").encode())
                def serve():
                    while not stop.is_set():
                        try:
                            connection, _ = listener.accept()
                            threading.Thread(target=handle, args=(connection,), daemon=True).start()
                        except socket.timeout:
                            pass
                server = threading.Thread(target=serve, daemon=True)
                server.start()
                helper = Path(__file__).resolve().parent.parent / "MacShell/niri_ipc.py"
                process = subprocess.Popen([sys.executable, "-u", str(helper)],
                                           env=dict(os.environ, NIRI_SOCKET=address), stdin=subprocess.PIPE,
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                buffer = b""
                def wait_state(predicate):
                    nonlocal buffer
                    deadline = time.monotonic() + 3
                    while time.monotonic() < deadline:
                        while b"\n" in buffer:
                            line, buffer = buffer.split(b"\n", 1)
                            message = json.loads(line)
                            if "state" in message and predicate(message["state"]):
                                return message["state"]
                        readable, _, _ = select.select([process.stdout], [], [], .1)
                        if readable:
                            buffer += os.read(process.stdout.fileno(), 65536)
                    self.fail("Bridge did not deliver the expected state")
                try:
                    connection = stream.get(timeout=3)
                    self.assertEqual(wait_state(lambda s: len(s["windows"]) == 1)["windows"][0]["id"], 42)
                    command = {"Action": {"FocusWindow": {"id": 42}}}
                    process.stdin.write((json.dumps(command) + "\n").encode())
                    process.stdin.flush()
                    self.assertEqual(actions.get(timeout=3), command)
                    encoded = json.dumps({"WindowClosed": {"id": 42}}).encode() + b"\n"
                    connection.sendall(encoded[:8])
                    connection.sendall(encoded[8:])
                    self.assertEqual(wait_state(lambda s: not s["windows"])["windows"], [])
                finally:
                    process.terminate()
                    process.communicate(timeout=3)
                    stop.set()
                    server.join(timeout=2)


if __name__ == "__main__":
    unittest.main()

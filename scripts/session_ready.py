#!/usr/bin/env python3
"""Fail the session startup if the shell never connects to its compositor."""
import json
import subprocess
import sys
import time


def wait_ready(launcher, timeout=15):
    deadline = time.monotonic() + timeout
    last_error = "No status received"
    while time.monotonic() < deadline:
        try:
            result = subprocess.run([str(launcher), "ipc", "call", "status", "state"],
                                    capture_output=True, text=True, timeout=min(2, max(.1, deadline - time.monotonic())))
            if result.returncode == 0:
                status = json.loads(result.stdout)
                if isinstance(status, dict) and status.get("connected") is True:
                    return
            last_error = (result.stderr or result.stdout).strip()
        except (OSError, ValueError, subprocess.TimeoutExpired) as error:
            last_error = str(error)
        time.sleep(.2)
    raise RuntimeError("MacShell did not connect within the startup deadline: " + last_error[-1500:])


if __name__ == "__main__":
    try:
        wait_ready(sys.argv[1])
    except RuntimeError as error:
        print(error, file=sys.stderr)
        sys.exit(1)

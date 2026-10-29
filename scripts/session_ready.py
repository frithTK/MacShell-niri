#!/usr/bin/env python3
"""Fail the session startup if the shell never connects to its compositor."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time


def graphical_polkit_agent_running(proc=Path("/proc")):
    """Avoid competing with an existing graphical agent for this user."""
    uid = os.getuid()
    try:
        entries = list(proc.iterdir())
    except OSError:
        return False
    for entry in entries:
        if not entry.name.isdigit():
            continue
        try:
            if entry.stat().st_uid != uid:
                continue
        except OSError:
            continue
        try:
            executable = os.path.basename(os.readlink(entry / "exe")).lower()
        except OSError:
            try:
                executable = os.path.basename(os.fsdecode((entry / "cmdline").read_bytes().split(b"\0", 1)[0])).lower()
            except OSError:
                continue
        if executable != "pkttyagent" and "polkit" in executable and ("agent" in executable or "auth" in executable):
            return True
    return False


def ensure_polkit_agent():
    """Start an installed graphical agent after niri is ready, when needed."""
    if graphical_polkit_agent_running():
        return "already_running"
    candidates = (
        "/usr/lib/polkit-kde-authentication-agent-1",
        "/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1",
        "/usr/libexec/polkit-gnome-authentication-agent-1",
        shutil.which("lxqt-policykit-agent"),
        shutil.which("hyprpolkitagent"),
        shutil.which("polkit-mate-authentication-agent-1"),
    )
    agent = next((p for p in candidates if p and os.path.isfile(p) and os.access(p, os.X_OK)), None)
    if not agent:
        return "unavailable"
    command = ["systemd-run", "--user", "--unit=macshell-polkit-agent", "--collect", "--service-type=exec",
               "--property=Restart=on-failure", "--property=RestartSec=2", "--property=PartOf=niri-macshell.service", agent]
    result = subprocess.run(command, capture_output=True, text=True, timeout=10)
    return "started" if result.returncode == 0 else "failed"


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
    try:
        agent_status = ensure_polkit_agent()
        if agent_status in ("unavailable", "failed"):
            print("MacShell: no graphical PolicyKit agent is available.", file=sys.stderr)
    except (OSError, subprocess.SubprocessError) as error:
        print("MacShell: could not start the PolicyKit agent:", error, file=sys.stderr)

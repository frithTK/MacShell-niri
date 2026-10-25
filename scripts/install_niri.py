#!/usr/bin/env python3
"""Per-user niri installer with validation, snapshots and rollback."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

if __package__:
    from .session_preflight import check_runtime
else:
    from session_preflight import check_runtime

SOURCE = Path(__file__).resolve().parent.parent
CONFIG = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
CACHE = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
DATA = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "macshell-niri"
BIN = Path(os.environ.get("MACSHELL_BIN_DIR", Path.home() / ".local/bin"))
PROFILE = CONFIG / "macshell-niri"
SHELL = CONFIG / "quickshell/MacShell-niri"
LOCK = CONFIG / "quickshell/MacLock-niri"
NIRI = CONFIG / "niri/config.kdl"
SESSION_UNIT = CONFIG / "systemd/user/niri-macshell.service"


def quickshell():
    local = DATA / "runtime/bin/qs"
    return os.environ.get("MACSHELL_QS_BIN") or (str(local) if local.is_file() else shutil.which("qs") or "qs")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None


def remove(path):
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)


def copy(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if source.is_symlink():
        destination.symlink_to(os.readlink(source))
    elif source.is_dir():
        shutil.copytree(source, destination, symlinks=True)
    else:
        shutil.copy2(source, destination)


def validate(path):
    subprocess.run(["niri", "validate", "-c", str(path)], check=True, capture_output=True, text=True)


def runtime_check():
    missing = [name for name in ("niri", "python3", quickshell()) if not shutil.which(name)]
    if missing:
        raise RuntimeError("Missing required programs: " + ", ".join(missing))
    check_runtime(quickshell())


def doctor():
    ok = True
    try:
        runtime_check()
        print("OK: niri and Quickshell runtime")
    except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        print("ERROR:", error)
        ok = False
    shell_path = str(Path(quickshell()).parent) + os.pathsep + os.environ.get("PATH", "")
    for name in ("jq", "grim", "wl-copy", "wl-paste", "wtype", "brightnessctl", "nmcli", "wlsunset", "wf-recorder", "slurp", "pw-dump", "pw-loopback", "ffprobe", "cliphist", "mpvpaper", "doubletake", "uxplay"):
        present = shutil.which(name, path=shell_path)
        if not present and name in ("doubletake", "uxplay"):
            present = shutil.which(name, path=str(DATA / "runtime/bin"))
        print(("OK: " if present else "OPTIONAL MISSING: ") + name)
    if not (shutil.which("qsb") or Path("/usr/lib/qt6/bin/qsb").exists()):
        print("ERROR: Liquid Glass needs qt6-shadertools")
        ok = False
    probe = subprocess.run([sys.executable, "-c", 'import gi; gi.require_version("Gst", "1.0"); gi.require_version("GstVideo", "1.0"); from PIL import Image'], capture_output=True)
    print("OK: Python capture dependencies" if probe.returncode == 0 else "ERROR: previews need python-gobject, python-pillow and gst-python")
    ok &= probe.returncode == 0
    gst = shutil.which("gst-inspect-1.0")
    for plugin in ("pipewiresrc", "capssetter", "videoscale", "videoconvert", "appsink"):
        result = subprocess.run([gst, plugin], capture_output=True) if gst else None
        if not result or result.returncode:
            print("ERROR: missing GStreamer element:", plugin)
            ok = False
    return ok


def launcher(lock=False):
    env = {"MACSHELL_SETTINGS_HOME": str(PROFILE / "settings"), "MACSHELL_LOCK_HELPER": str(BIN / "maclock-niri"),
           "XDG_CACHE_HOME": str(CACHE / "macshell-niri"), "MACSHELL_WALLPAPER_CACHE_HOME": str(CACHE),
           "MACSHELL_QS_BIN": quickshell()}
    if not lock:
        env.update(MACSHELL_INPUT_FRAGMENT=str(PROFILE / "niri/macshell-input.kdl"), MACSHELL_NIRI_PROFILE=str(PROFILE / "niri"))
    text = "#!/usr/bin/env bash\nset -euo pipefail\n"
    text += "".join(f"export {key}={shlex.quote(value)}\n" for key, value in env.items())
    text += 'export PATH=' + shlex.quote(str(Path(quickshell()).parent)) + ':"$PATH"\n'
    text += 'export QT_QUICK_CONTROLS_STYLE="${QT_QUICK_CONTROLS_STYLE:-Basic}"\n'
    return text + (f'exec sh {shlex.quote(str(LOCK / "lock-via-ipc.sh"))} "$@"\n' if lock else 'exec "$MACSHELL_QS_BIN" -c MacShell-niri "$@"\n')


def session_files():
    preflight = PROFILE / "session-preflight.py"
    shutil.copy2(SOURCE / "scripts/session_preflight.py", preflight)
    ready = PROFILE / "session-ready.py"
    shutil.copy2(SOURCE / "scripts/session_ready.py", ready)
    script = (SOURCE / "scripts/niri-macshell-session.sh").read_text()
    for token, value in {"@PROFILE_CONFIG@": PROFILE / "niri/config.kdl", "@PREFLIGHT@": preflight, "@QS_BINARY@": quickshell()}.items():
        script = script.replace(token, shlex.quote(str(value)))
    path = BIN / "niri-macshell-session"
    path.write_text(script)
    path.chmod(0o755)
    SESSION_UNIT.parent.mkdir(parents=True, exist_ok=True)
    def unit_arg(path):
        return '"' + str(path).replace("%", "%%").replace("\\", "\\\\").replace('"', '\\"') + '"'
    SESSION_UNIT.write_text('[Unit]\nDescription=niri with the separate MacShell profile\nBindsTo=graphical-session.target\nBefore=graphical-session.target\nWants=graphical-session-pre.target\nAfter=graphical-session-pre.target\nWants=xdg-desktop-autostart.target\nBefore=xdg-desktop-autostart.target\n\n[Service]\nSlice=session.slice\nType=notify\nTimeoutStartSec=30\nTimeoutStopSec=10\nExecStart=/usr/bin/niri --session --config ' + unit_arg(PROFILE / "niri/config.kdl") + '\nExecStartPost=/usr/bin/python3 ' + unit_arg(ready) + ' ' + unit_arg(BIN / "macshell-niri") + '\n')
    bundle = DATA / "session"
    bundle.mkdir(parents=True, exist_ok=True)
    for source in ("scripts/register-session.sh", "scripts/session-entry.sh", "config/niri-macshell.desktop"):
        shutil.copy2(SOURCE / source, bundle / Path(source).name)
    subprocess.run(["desktop-file-validate", str(bundle / "niri-macshell.desktop")], check=True, capture_output=True)
    subprocess.run(["systemctl", "--user", "daemon-reload"], check=True, capture_output=True)


IPC_MAP = {"launcher toggle": "spotlight toggle", "lockScreen lock": "session lock", "sessionMenu toggle": "session menu", "media prev": "media previous"}


def prepare_niri(destination):
    if not NIRI.is_file():
        raise RuntimeError(f"Existing niri config not found: {NIRI}")
    # Independent copy: never edit through the user's config symlinks.
    source = PROFILE / "niri" if NIRI.read_text().startswith("// Original config snapshot:") else NIRI.parent
    shutil.copytree(source, destination, symlinks=False)
    previous_shell = any("qs -c noctalia-shell" in file.read_text() for file in destination.rglob("*.kdl"))
    saved_input = (destination / "macshell-input.kdl").read_text() if (destination / "macshell-input.kdl").exists() else "// Input preferences remain unchanged until edited in MacShell.\n"
    (destination / "macshell.kdl").unlink(missing_ok=True)
    (destination / "macshell-input.kdl").unlink(missing_ok=True)
    keys = set()
    shell_launcher = json.dumps(shlex.quote(str(BIN / "macshell-niri")))[1:-1]
    for file in destination.rglob("*.kdl"):
        content = file.read_text()
        content = re.sub(r'qs\s+-c\s+noctalia-shell\s+ipc\s+call\s+([A-Za-z]+\s+[A-Za-z]+)', lambda m: shell_launcher + " ipc call " + IPC_MAP.get(m[1], m[1]), content)
        content = re.sub(r'qs\s+-c\s+noctalia-shell(?=["\s]|$)', lambda _: shell_launcher, content)
        keys.update(m[1].lower() for m in re.finditer(r'^\s*([\w+]+)\s+(?:[^\n{]*\s)?\{', content, re.MULTILINE) if "+" in m[1] or m[1] == "Print")
        file.write_text(content)
    extra = []
    for line in (SOURCE / "config/macshell.kdl").read_text().splitlines():
        match = re.match(r'\s*([\w+]+)\s+\{\s*spawn', line)
        if match and match[1].lower() in keys:
            print("Preserving existing keybind:", match[1])
        else:
            extra.append(line)
    bindings = "\n".join(extra).replace('"qs" "-c" "MacShell-niri"', json.dumps(str(BIN / "macshell-niri")))
    (destination / "macshell.kdl").write_text(bindings + "\n")
    (destination / "macshell-input.kdl").write_text(saved_input)
    current = destination / "config.kdl"
    content = re.sub(r'^include "\./macshell(?:-input)?\.kdl"\s*$', '', current.read_text(), flags=re.MULTILINE) + '\ninclude "./macshell.kdl"\ninclude "./macshell-input.kdl"\n'
    if not any(str(BIN / "macshell-niri") in file.read_text() for file in destination.rglob("*.kdl")):
        content += "spawn-at-startup " + json.dumps(str(BIN / "macshell-niri")) + "\n"
    current.write_text(content)
    validate(current)
    return previous_shell


def snapshot(paths):
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]
    directory = DATA / "backups" / stamp
    directory.mkdir(parents=True, mode=0o700)
    entries = []
    for index, path in enumerate(paths):
        exists = path.exists() or path.is_symlink()
        backup = directory / f"before/{index}"
        if exists:
            copy(path, backup)
        entries.append({"path": str(path), "backup": str(backup), "existed": exists})
    latest = (DATA / "latest").read_text() if (DATA / "latest").exists() else None
    manifest = {"entries": entries, "niri_digest": None, "activated": False, "previous_shell": None, "previous_latest": latest}
    (directory / "manifest.json").write_text(json.dumps(manifest, indent=2))
    return directory, manifest


def restore(directory, manifest, force=False):
    expected = manifest.get("niri_digest")
    if expected and digest(NIRI) != expected and not force:
        raise RuntimeError(f"niri/config.kdl changed after installation. Inspect {directory} before --rollback --force.")
    for index, entry in reversed(list(enumerate(manifest["entries"]))):
        path = Path(entry["path"])
        if path.exists() or path.is_symlink():
            after = directory / f"after/{index}"
            remove(after)
            copy(path, after)
            remove(path)
        if entry["existed"]:
            copy(Path(entry["backup"]), path)
    if manifest.get("previous_latest"):
        (DATA / "latest").write_text(manifest["previous_latest"])
    else:
        (DATA / "latest").unlink(missing_ok=True)


def start_previous(name):
    if name:
        command = [str(BIN / "macshell-niri")] if name == "MacShell-niri" else ["qs", "-c", name]
        subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def install(activate=False, session=False):
    if os.geteuid() == 0:
        raise RuntimeError("Run as your desktop user, without sudo.")
    if not activate and not session and NIRI.is_file() and NIRI.read_text().startswith("// Original config snapshot:"):
        raise RuntimeError("MacShell is already active. Use --activate to update it with session recovery.")
    if activate or session:
        runtime_check()
    with tempfile.TemporaryDirectory(prefix="macshell-install-") as temporary:
        staged = Path(temporary) / "niri"
        previous_port = activate and NIRI.is_file() and NIRI.read_text().startswith("// Original config snapshot:")
        if activate or session:
            previous_shell = prepare_niri(staged)
        targets = [SHELL, LOCK, BIN / "macshell-niri", BIN / "maclock-niri", PROFILE] + ([NIRI] if activate else [])
        if session:
            targets += [SESSION_UNIT, BIN / "niri-macshell-session", DATA / "session"]
        directory, manifest = snapshot(targets)
        if activate:
            manifest["previous_shell"] = "MacShell-niri" if previous_port else "noctalia-shell" if previous_shell else None
        previous_stopped = False
        try:
            if previous_port:
                subprocess.run(["qs", "-c", "MacShell-niri", "kill"], capture_output=True)
                previous_stopped = True
            for source, destination in ((SOURCE / "MacShell", SHELL), (SOURCE / "MacLock", LOCK)):
                remove(destination)
                shutil.copytree(source, destination, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
            (PROFILE / "settings").mkdir(parents=True, exist_ok=True)
            BIN.mkdir(parents=True, exist_ok=True)
            for name, lock in (("macshell-niri", False), ("maclock-niri", True)):
                path = BIN / name
                remove(path)
                path.write_text(launcher(lock))
                path.chmod(0o755)
            if activate or session:
                remove(PROFILE / "niri")
                shutil.copytree(staged, PROFILE / "niri")
            if session:
                session_files()
                manifest["session_only"] = True
            if activate:
                wrapper = NIRI.with_suffix(".macshell-new.kdl")
                wrapper.write_text(f"// Original config snapshot: {directory}\ninclude " + json.dumps(str(PROFILE / "niri/config.kdl")) + "\n")
                validate(wrapper)
                os.replace(wrapper, NIRI)
                manifest.update(niri_digest=digest(NIRI), activated=True)
            (directory / "manifest.json").write_text(json.dumps(manifest, indent=2))
            (DATA / "latest").write_text(str(directory))
            if activate:
                (directory / "manifest.json").write_text(json.dumps(manifest, indent=2))
                subprocess.run(["niri", "msg", "action", "load-config-file"], check=True, capture_output=True)
                if previous_shell:
                    subprocess.run(["qs", "-c", "noctalia-shell", "kill"], capture_output=True)
                    previous_stopped = True
                logs = DATA / "logs"
                logs.mkdir(exist_ok=True)
                with (logs / "shell.log").open("w") as log:
                    process = subprocess.Popen([str(BIN / "macshell-niri")], stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                ready = False
                for _ in range(30):
                    status = subprocess.run(["qs", "-c", "MacShell-niri", "ipc", "call", "status", "state"], capture_output=True, text=True)
                    if status.returncode == 0 and '"connected":true' in status.stdout:
                        ready = True
                        break
                    if process.poll() is not None:
                        break
                    time.sleep(.2)
                if not ready:
                    process.terminate()
                    process.wait(timeout=5)
                    raise RuntimeError("MacShell did not become ready; reverting configuration. Log: " + str(logs / "shell.log"))
        except Exception:
            restore(directory, manifest)
            if manifest.get("activated"):
                subprocess.run(["niri", "msg", "action", "load-config-file"], capture_output=True)
            if previous_stopped:
                start_previous(manifest.get("previous_shell"))
            raise
    print("Installed MacShell-niri and MacLock-niri.\nBackup:", directory)
    print("Start:", BIN / "macshell-niri", "\nRollback: bash install.sh --rollback")
    if session:
        print("Original niri configuration and running desktop are unchanged.")
        print("Register the login option: sudo bash", DATA / "session/register-session.sh")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--check", action="store_true")
    modes.add_argument("--dry-run", action="store_true")
    modes.add_argument("--rollback", action="store_true")
    parser.add_argument("--activate", action="store_true")
    parser.add_argument("--session", action="store_true", help="Prepare a separate SDDM login choice without changing the current niri config")
    parser.add_argument("--force", action="store_true", help="Allow rollback after root niri config edits")
    args = parser.parse_args()
    if args.activate and args.session:
        parser.error("Choose either --session or --activate")
    if args.check:
        return 0 if doctor() else 1
    if args.dry_run:
        print("Shell:", SHELL, "\nLock:", LOCK, "\nSettings:", PROFILE / "settings", "\nLaunchers:", BIN, "\nBackups:", DATA / "backups")
        if args.activate or args.session:
            with tempfile.TemporaryDirectory(prefix="macshell-plan-") as temporary:
                prepare_niri(Path(temporary) / "niri")
            print("Generated niri configuration validates successfully.")
        return 0
    if args.rollback:
        directory = Path((DATA / "latest").read_text().strip())
        manifest = json.loads((directory / "manifest.json").read_text())
        if manifest.get("niri_digest") and digest(NIRI) != manifest["niri_digest"] and not args.force:
            raise RuntimeError("niri config was edited; inspect the backup before forcing rollback.")
        if manifest["activated"]:
            subprocess.run(["qs", "-c", "MacShell-niri", "kill"], capture_output=True)
        restore(directory, manifest, args.force)
        if manifest.get("session_only"):
            subprocess.run(["systemctl", "--user", "daemon-reload"], check=False, capture_output=True)
        if manifest["activated"]:
            subprocess.run(["niri", "msg", "action", "load-config-file"], capture_output=True)
            start_previous(manifest.get("previous_shell"))
        print("Restored:", directory, "\nPost-install files were preserved in its after/ directory.")
        return 0
    install(args.activate, args.session)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print("ERROR:", error, file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError):
            print(error.stderr or "", file=sys.stderr)
        sys.exit(1)

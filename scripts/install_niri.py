#!/usr/bin/env python3
"""Per-user niri installer with validation, snapshots and rollback."""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
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
SHELL_UNIT = CONFIG / "systemd/user/macshell-niri-shell.service"


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
    missing = [name for name in ("niri", "python3", "systemctl", "systemd-run", "flock", "timeout", quickshell()) if not shutil.which(name)]
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
    print("OK: Rust update backend is built during Rust installation")
    if not (shutil.which("qsb") or Path("/usr/lib/qt6/bin/qsb").exists()):
        print("ERROR: Liquid Glass needs qt6-shadertools")
        ok = False
    probe = subprocess.run([sys.executable, "-c", 'import gi; gi.require_version("Gst", "1.0"); gi.require_version("GstVideo", "1.0"); from PIL import Image'], capture_output=True)
    print("OK: Python capture dependencies" if probe.returncode == 0 else "ERROR: previews need python-gobject, python-pillow and gst-python")
    ok &= probe.returncode == 0
    gst = shutil.which("gst-inspect-1.0")
    for plugin in ("pipewiresrc", "capssetter", "videoscale", "videoconvert", "appsink", "appsrc", "pngenc"):
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
    if lock:
        return text + f'exec sh {shlex.quote(str(LOCK / "lock-via-ipc.sh"))} "$@"\n'
    text += 'if [[ $# -eq 0 && ${MACSHELL_MANAGED_SHELL:-} == 1 && ${MACSHELL_SERVICE_CHILD:-} != 1 ]]; then\n'
    supervisor = shlex.quote(str(PROFILE / "shell-supervisor.sh"))
    legacy = shlex.quote(str(PROFILE / "shell-supervisor.py"))
    text += f'    if [[ -f {supervisor} ]]; then\n        exec sh {supervisor} start\n    fi\n    exec python3 {legacy} start\nfi\n'
    return text + 'unset MACSHELL_SERVICE_CHILD\nexec "$MACSHELL_QS_BIN" -c MacShell-niri "$@"\n'


def session_files(locale_binary=None, preflight_binary=None):
    # A legacy session can replace a Rust session in the same profile.
    # Do not retain its Rust-only policy when installing Python helpers.
    if not locale_binary or not preflight_binary:
        (PROFILE / ".macshell-rust-only").unlink(missing_ok=True)
    shutil.copy2(SOURCE / "scripts/session_preflight.py", PROFILE / "session-preflight.py")
    preflight = PROFILE / "session-preflight.sh"
    shutil.copy2(SOURCE / "scripts/session-preflight.sh", preflight)
    preflight.chmod(0o755)
    installed_preflight = PROFILE / "session-preflight-rust"
    remove(installed_preflight)
    if preflight_binary:
        shutil.copy2(preflight_binary, installed_preflight)
        installed_preflight.chmod(0o755)
    ready = PROFILE / "session-ready.py"
    shutil.copy2(SOURCE / "scripts/session_ready.py", ready)
    ready_launcher = PROFILE / "session-ready.sh"
    shutil.copy2(SOURCE / "scripts/session-ready.sh", ready_launcher)
    ready_launcher.chmod(0o755)
    supervisor = PROFILE / "shell-supervisor.py"
    shutil.copy2(SOURCE / "scripts/shell_supervisor.py", supervisor)
    supervisor_launcher = PROFILE / "shell-supervisor.sh"
    shutil.copy2(SOURCE / "scripts/shell-supervisor.sh", supervisor_launcher)
    supervisor_launcher.chmod(0o755)
    shutil.copy2(SOURCE / "scripts/session_locale.py", PROFILE / "session-locale.py")
    shutil.copy2(SOURCE / "MacShell/locale_preferences.py", PROFILE / "locale_preferences.py")
    locale_helper = PROFILE / "session-locale.sh"
    shutil.copy2(SOURCE / "scripts/session-locale.sh", locale_helper)
    locale_helper.chmod(0o755)
    installed_locale = PROFILE / "locale-preferences-rust"
    remove(installed_locale)
    if locale_binary:
        shutil.copy2(locale_binary, installed_locale)
        installed_locale.chmod(0o755)
    script = (SOURCE / "scripts/niri-macshell-session.sh").read_text()
    for token, value in {"@PROFILE_CONFIG@": PROFILE / "niri/config.kdl", "@PREFLIGHT@": preflight, "@QS_BINARY@": quickshell(), "@LOCALE_HELPER@": locale_helper}.items():
        script = script.replace(token, shlex.quote(str(value)))
    path = BIN / "niri-macshell-session"
    path.write_text(script)
    path.chmod(0o755)
    SESSION_UNIT.parent.mkdir(parents=True, exist_ok=True)
    def unit_arg(path):
        return '"' + str(path).replace("%", "%%").replace("\\", "\\\\").replace('"', '\\"') + '"'
    SESSION_UNIT.write_text('[Unit]\nDescription=niri with the separate MacShell profile\nBindsTo=graphical-session.target\nBefore=graphical-session.target\nWants=graphical-session-pre.target\nAfter=graphical-session-pre.target\nWants=xdg-desktop-autostart.target\nBefore=xdg-desktop-autostart.target\n\n[Service]\nSlice=session.slice\nType=notify\nTimeoutStartSec=30\nTimeoutStopSec=10\nExecStart=/usr/bin/niri --session --config ' + unit_arg(PROFILE / "niri/config.kdl") + '\nExecStartPost=/bin/sh ' + unit_arg(ready_launcher) + ' ' + unit_arg(BIN / "macshell-niri") + '\nExecStopPost=-/usr/bin/systemctl --user stop macshell-niri-shell.service\n')
    SHELL_UNIT.write_text('[Unit]\nDescription=MacShell for the niri session\nPartOf=niri-macshell.service\nStartLimitIntervalSec=60\nStartLimitBurst=5\n\n[Service]\nSlice=session.slice\nType=exec\nEnvironment=MACSHELL_SERVICE_CHILD=1\nExecStartPre=/bin/sh ' + unit_arg(supervisor_launcher) + ' check ' + unit_arg(quickshell()) + '\nExecStart=' + unit_arg(BIN / "macshell-niri") + '\nRestart=on-failure\nRestartSec=2\nTimeoutStopSec=10\nKillMode=control-group\n')
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


def session_active():
    result = subprocess.run(["systemctl", "--user", "show", "niri-macshell.service", "--property=ActiveState", "--value"], capture_output=True, text=True, timeout=5)
    if result.returncode:
        raise RuntimeError("Cannot determine whether the MacShell session is active")
    return result.stdout.strip() not in ("inactive", "failed")


def instances(name):
    result = subprocess.run([quickshell(), "-c", name, "list", "--any-display", "--json"], check=True, capture_output=True, text=True, timeout=5)
    if result.stdout.startswith('No running instances for "') and result.stdout.rstrip().endswith('Use --all to list all instances.'):
        return []
    value = json.loads(result.stdout)
    if not isinstance(value, list):
        raise RuntimeError("Unexpected Quickshell instance list")
    return value


@contextmanager
def install_guard():
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if not runtime or not Path(runtime).is_dir():
        raise RuntimeError("Installation needs the user runtime directory")
    with (Path(runtime) / "macshell-niri-lock.guard").open("a") as guard:
        fcntl.flock(guard, fcntl.LOCK_EX)
        if instances("MacLock-niri"):
            state = subprocess.run([quickshell(), "-c", "MacLock-niri", "ipc", "call", "lockscreen", "state"], capture_output=True, text=True, timeout=5)
            if state.returncode or state.stdout.strip() != "ready":
                raise RuntimeError("MacLock is active or its state is unknown; unlock before changing the installation")
        yield


def stop_shell(name):
    if not instances(name):
        return False
    subprocess.run([quickshell(), "-c", name, "kill"], check=True, capture_output=True, timeout=5)
    deadline = time.monotonic() + 10
    while instances(name):
        if time.monotonic() >= deadline:
            raise RuntimeError(f"{name} did not stop; installation was not changed")
        time.sleep(.1)
    return True


def start_previous(name):
    if name:
        command = [str(BIN / "macshell-niri")] if name == "MacShell-niri" else ["qs", "-c", name]
        subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def build_niri_bridge(target):
    """Build before touching user files; Cargo must have its locked crates cached."""
    cargo = shutil.which("cargo")
    if not cargo:
        raise RuntimeError("Rust bridge needs Cargo; install Rust or select --python-bridge during the transition")
    manifest = SOURCE / "native/niri-bridge/Cargo.toml"
    if not manifest.is_file():
        raise RuntimeError("Rust bridge source is missing")
    command = [cargo, "build", "--release", "--locked", "--offline", "--manifest-path", str(manifest), "--target-dir", str(target)]
    result = subprocess.run(command, capture_output=True, text=True, timeout=300)
    if result.returncode:
        raise RuntimeError("Rust bridge build failed before installation. Rust 1.85+ and cached locked Cargo dependencies are required.\n" + result.stderr[-3000:])
    binary = target / "release/macshell-niri-bridge"
    check = subprocess.run([str(binary), "--protocol-version"], capture_output=True, text=True, timeout=5)
    if check.returncode or check.stdout.strip() != "macshell-niri-bridge 1":
        raise RuntimeError("Built Rust bridge failed the protocol check")
    return binary


def build_boot_clock(target):
    """Build the lock screen clock before replacing any installed files."""
    cargo = shutil.which("cargo")
    if not cargo:
        raise RuntimeError("Rust clock needs Cargo; install Rust or select --python-bridge during the transition")
    manifest = SOURCE / "native/boot-clock/Cargo.toml"
    if not manifest.is_file():
        raise RuntimeError("Rust clock source is missing")
    result = subprocess.run([cargo, "build", "--release", "--locked", "--offline", "--manifest-path", str(manifest),
                             "--target-dir", str(target)], capture_output=True, text=True, timeout=300)
    if result.returncode:
        raise RuntimeError("Rust clock build failed before installation. Rust 1.85+ and cached locked Cargo dependencies are required.\n" + result.stderr[-3000:])
    binary = target / "release/macshell-boot-clock"
    check = subprocess.run([str(binary), "--protocol-version"], capture_output=True, text=True, timeout=5)
    if check.returncode or check.stdout.strip() != "macshell-boot-clock 1":
        raise RuntimeError("Built Rust clock failed the protocol check")
    return binary


def build_system_stats(target):
    """Build the read-only system sampler before replacing installed files."""
    cargo = shutil.which("cargo")
    if not cargo:
        raise RuntimeError("Rust system stats needs Cargo; install Rust or select --python-bridge during the transition")
    manifest = SOURCE / "native/system-stats/Cargo.toml"
    if not manifest.is_file():
        raise RuntimeError("Rust system stats source is missing")
    result = subprocess.run([cargo, "build", "--release", "--locked", "--offline", "--manifest-path", str(manifest),
                             "--target-dir", str(target)], capture_output=True, text=True, timeout=300)
    if result.returncode:
        raise RuntimeError("Rust system stats build failed before installation. Rust 1.85+ and cached locked Cargo dependencies are required.\n" + result.stderr[-3000:])
    binary = target / "release/macshell-system-stats"
    check = subprocess.run([str(binary), "--protocol-version"], capture_output=True, text=True, timeout=5)
    if check.returncode or check.stdout.strip() != "macshell-system-stats 1":
        raise RuntimeError("Built Rust system stats failed the protocol check")
    return binary


def build_night_shift(target):
    """Build the Night Shift process owner before replacing installed files."""
    cargo = shutil.which("cargo")
    if not cargo:
        raise RuntimeError("Rust Night Shift needs Cargo; install Rust or select --python-bridge during the transition")
    manifest = SOURCE / "native/night-shift/Cargo.toml"
    if not manifest.is_file():
        raise RuntimeError("Rust Night Shift source is missing")
    result = subprocess.run([cargo, "build", "--release", "--locked", "--offline", "--manifest-path", str(manifest),
                             "--target-dir", str(target)], capture_output=True, text=True, timeout=300)
    if result.returncode:
        raise RuntimeError("Rust Night Shift build failed before installation. Rust 1.85+ and cached locked Cargo dependencies are required.\n" + result.stderr[-3000:])
    binary = target / "release/macshell-night-shift"
    check = subprocess.run([str(binary), "--protocol-version"], capture_output=True, text=True, timeout=5)
    if check.returncode or check.stdout.strip() != "macshell-night-shift 1":
        raise RuntimeError("Built Rust Night Shift failed the protocol check")
    return binary


def build_timed_modes(target):
    """Build focus and idle-inhibition deadlines before replacing installed files."""
    cargo = shutil.which("cargo")
    if not cargo:
        raise RuntimeError("Rust timed modes needs Cargo; install Rust or select --python-bridge during the transition")
    manifest = SOURCE / "native/timed-modes/Cargo.toml"
    if not manifest.is_file():
        raise RuntimeError("Rust timed modes source is missing")
    result = subprocess.run([cargo, "build", "--release", "--locked", "--offline", "--manifest-path", str(manifest),
                             "--target-dir", str(target)], capture_output=True, text=True, timeout=300)
    if result.returncode:
        raise RuntimeError("Rust timed modes build failed before installation. Rust 1.85+ and cached locked Cargo dependencies are required.\n" + result.stderr[-3000:])
    binary = target / "release/macshell-timed-modes"
    check = subprocess.run([str(binary), "--protocol-version"], capture_output=True, text=True, timeout=5)
    if check.returncode or check.stdout.strip() != "macshell-timed-modes 1":
        raise RuntimeError("Built Rust timed modes failed the protocol check")
    return binary


def build_activity_preferences(target):
    """Build the transactional Activity settings service before installation."""
    cargo = shutil.which("cargo")
    if not cargo:
        raise RuntimeError("Rust Activity preferences needs Cargo; install Rust or select --python-bridge during the transition")
    manifest = SOURCE / "native/activity-preferences/Cargo.toml"
    if not manifest.is_file():
        raise RuntimeError("Rust Activity preferences source is missing")
    result = subprocess.run([cargo, "build", "--release", "--locked", "--offline", "--manifest-path", str(manifest),
                             "--target-dir", str(target)], capture_output=True, text=True, timeout=300)
    if result.returncode:
        raise RuntimeError("Rust Activity preferences build failed before installation. Rust 1.85+ and cached locked Cargo dependencies are required.\n" + result.stderr[-3000:])
    binary = target / "release/macshell-activity-preferences"
    check = subprocess.run([str(binary), "--protocol-version"], capture_output=True, text=True, timeout=5)
    if check.returncode or check.stdout.strip() != "macshell-activity-preferences 1":
        raise RuntimeError("Built Rust Activity preferences failed the protocol check")
    return binary


def build_bar_preferences(target):
    """Build the transactional menu bar settings service before installation."""
    cargo = shutil.which("cargo")
    if not cargo:
        raise RuntimeError("Rust menu bar preferences needs Cargo; install Rust or select --python-bridge during the transition")
    manifest = SOURCE / "native/bar-preferences/Cargo.toml"
    if not manifest.is_file():
        raise RuntimeError("Rust menu bar preferences source is missing")
    result = subprocess.run([cargo, "build", "--release", "--locked", "--offline", "--manifest-path", str(manifest),
                             "--target-dir", str(target)], capture_output=True, text=True, timeout=300)
    if result.returncode:
        raise RuntimeError("Rust menu bar preferences build failed before installation. Rust 1.85+ and cached locked Cargo dependencies are required.\n" + result.stderr[-3000:])
    binary = target / "release/macshell-bar-preferences"
    check = subprocess.run([str(binary), "--protocol-version"], capture_output=True, text=True, timeout=5)
    if check.returncode or check.stdout.strip() != "macshell-bar-preferences 1":
        raise RuntimeError("Built Rust menu bar preferences failed the protocol check")
    return binary


def build_widget_preferences(target):
    """Build widget settings before replacing any installed files."""
    cargo = shutil.which("cargo")
    if not cargo:
        raise RuntimeError("Rust widget preferences needs Cargo; install Rust or select --python-bridge during the transition")
    manifest = SOURCE / "native/widget-preferences/Cargo.toml"
    if not manifest.is_file():
        raise RuntimeError("Rust widget preferences source is missing")
    result = subprocess.run([cargo, "build", "--release", "--locked", "--offline", "--manifest-path", str(manifest),
                             "--target-dir", str(target)], capture_output=True, text=True, timeout=300)
    if result.returncode:
        raise RuntimeError("Rust widget preferences build failed before installation. Rust 1.85+ and cached locked Cargo dependencies are required.\n" + result.stderr[-3000:])
    binary = target / "release/macshell-widget-preferences"
    check = subprocess.run([str(binary), "--protocol-version"], capture_output=True, text=True, timeout=5)
    if check.returncode or check.stdout.strip() != "macshell-widget-preferences 1":
        raise RuntimeError("Built Rust widget preferences failed the protocol check")
    return binary


def build_locale_preferences(target):
    """Build the shared Settings and session locale service before installation."""
    cargo = shutil.which("cargo")
    if not cargo:
        raise RuntimeError("Rust locale preferences needs Cargo; install Rust or select --python-bridge during the transition")
    manifest = SOURCE / "native/locale-preferences/Cargo.toml"
    if not manifest.is_file():
        raise RuntimeError("Rust locale preferences source is missing")
    result = subprocess.run([cargo, "build", "--release", "--locked", "--offline", "--manifest-path", str(manifest),
                             "--target-dir", str(target)], capture_output=True, text=True, timeout=300)
    if result.returncode:
        raise RuntimeError("Rust locale preferences build failed before installation. Rust 1.85+ and cached locked Cargo dependencies are required.\n" + result.stderr[-3000:])
    binary = target / "release/macshell-locale-preferences"
    check = subprocess.run([str(binary), "--protocol-version"], capture_output=True, text=True, timeout=5)
    if check.returncode or check.stdout.strip() != "macshell-locale-preferences 1":
        raise RuntimeError("Built Rust locale preferences failed the protocol check")
    return binary


def build_native_blur(target):
    """Build the scoped native blur helper before replacing any installed files."""
    cargo = shutil.which("cargo")
    if not cargo:
        raise RuntimeError("Rust native blur needs Cargo; install Rust or select --python-bridge during the transition")
    manifest = SOURCE / "native/native-blur/Cargo.toml"
    if not manifest.is_file():
        raise RuntimeError("Rust native blur source is missing")
    result = subprocess.run([cargo, "build", "--release", "--locked", "--offline", "--manifest-path", str(manifest),
                             "--target-dir", str(target)], capture_output=True, text=True, timeout=300)
    if result.returncode:
        raise RuntimeError("Rust native blur build failed before installation. Rust 1.85+ and cached locked Cargo dependencies are required.\n" + result.stderr[-3000:])
    binary = target / "release/macshell-native-blur"
    check = subprocess.run([str(binary), "--protocol-version"], capture_output=True, text=True, timeout=5)
    if check.returncode or check.stdout.strip() != "macshell-native-blur 1":
        raise RuntimeError("Built Rust native blur failed the protocol check")
    return binary


def build_session_preflight(target):
    """Build the isolated session preflight before replacing installed files."""
    cargo = shutil.which("cargo")
    if not cargo:
        raise RuntimeError("Rust session preflight needs Cargo; install Rust or select --python-bridge during the transition")
    manifest = SOURCE / "native/session-preflight/Cargo.toml"
    if not manifest.is_file():
        raise RuntimeError("Rust session preflight source is missing")
    result = subprocess.run([cargo, "build", "--release", "--locked", "--offline", "--manifest-path", str(manifest),
                             "--target-dir", str(target)], capture_output=True, text=True, timeout=300)
    if result.returncode:
        raise RuntimeError("Rust session preflight build failed before installation. Rust 1.85+ and cached locked Cargo dependencies are required.\n" + result.stderr[-3000:])
    binary = target / "release/macshell-session-preflight"
    check = subprocess.run([str(binary), "--protocol-version"], capture_output=True, text=True, timeout=5)
    if check.returncode or check.stdout.strip() != "macshell-session-preflight 1":
        raise RuntimeError("Built Rust session preflight failed the protocol check")
    check = subprocess.run([str(binary), "--ready-protocol-version"], capture_output=True, text=True, timeout=5)
    if check.returncode or check.stdout.strip() != "macshell-session-ready 1":
        raise RuntimeError("Built Rust session readiness helper failed the protocol check")
    check = subprocess.run([str(binary), "--supervisor-protocol-version"], capture_output=True, text=True, timeout=5)
    if check.returncode or check.stdout.strip() != "macshell-shell-supervisor 1":
        raise RuntimeError("Built Rust shell supervisor failed the protocol check")
    return binary


def build_power_profiles(target):
    """Build the Gio power profiles service before replacing installed files."""
    cargo = shutil.which("cargo")
    if not cargo:
        raise RuntimeError("Rust power profiles needs Cargo; install Rust or select --python-bridge during the transition")
    manifest = SOURCE / "native/power-profiles/Cargo.toml"
    if not manifest.is_file():
        raise RuntimeError("Rust power profiles source is missing")
    result = subprocess.run([cargo, "build", "--release", "--locked", "--offline", "--manifest-path", str(manifest),
                             "--target-dir", str(target)], capture_output=True, text=True, timeout=300)
    if result.returncode:
        raise RuntimeError("Rust power profiles build failed before installation. Rust 1.85+, Gio/GLib linker libraries and cached locked Cargo dependencies are required.\n" + result.stderr[-3000:])
    binary = target / "release/macshell-power-profiles"
    check = subprocess.run([str(binary), "--protocol-version"], capture_output=True, text=True, timeout=5)
    if check.returncode or check.stdout.strip() != "macshell-power-profiles 1":
        raise RuntimeError("Built Rust power profiles failed the protocol check")
    return binary


def build_niri_color(target):
    """Build the explicit niri color-picker helper before installation."""
    cargo = shutil.which("cargo")
    if not cargo:
        raise RuntimeError("Rust niri color picker needs Cargo; install Rust or select --python-bridge during the transition")
    manifest = SOURCE / "native/niri-color/Cargo.toml"
    if not manifest.is_file():
        raise RuntimeError("Rust niri color picker source is missing")
    result = subprocess.run([cargo, "build", "--release", "--locked", "--offline", "--manifest-path", str(manifest),
                             "--target-dir", str(target)], capture_output=True, text=True, timeout=300)
    if result.returncode:
        raise RuntimeError("Rust niri color picker build failed before installation. Rust 1.85+ and cached locked Cargo dependencies are required.\n" + result.stderr[-3000:])
    binary = target / "release/macshell-niri-color"
    check = subprocess.run([str(binary), "--protocol-version"], capture_output=True, text=True, timeout=5)
    if check.returncode or check.stdout.strip() != "macshell-niri-color 1":
        raise RuntimeError("Built Rust niri color picker failed the protocol check")
    return binary


def build_bluetooth(target):
    """Build the BlueZ service before replacing installed files."""
    cargo = shutil.which("cargo")
    if not cargo:
        raise RuntimeError("Rust Bluetooth needs Cargo; install Rust or select --python-bridge during the transition")
    manifest = SOURCE / "native/bluez-session/Cargo.toml"
    if not manifest.is_file():
        raise RuntimeError("Rust Bluetooth source is missing")
    result = subprocess.run([cargo, "build", "--release", "--locked", "--offline", "--manifest-path", str(manifest),
                             "--bin", "macshell-bluetooth", "--target-dir", str(target)], capture_output=True, text=True, timeout=300)
    if result.returncode:
        raise RuntimeError("Rust Bluetooth build failed before installation. Rust 1.85+, Gio/GLib linker libraries and cached locked Cargo dependencies are required.\n" + result.stderr[-3000:])
    binary = target / "release/macshell-bluetooth"
    check = subprocess.run([str(binary), "--protocol-version"], capture_output=True, text=True, timeout=5)
    if check.returncode or check.stdout.strip() != "macshell-bluetooth 1":
        raise RuntimeError("Built Rust Bluetooth service failed the protocol check")
    return binary


def build_media_service(target, kind):
    """Build and verify a media service before touching the installed shell."""
    services = {
        "capture": ("capture-service", "macshell-capture-experimental", "macshell-capture 1"),
        "recording": ("recording-core", "macshell-recording-experimental", "macshell-recording 1"),
    }
    crate, program, protocol = services[kind]
    cargo = shutil.which("cargo")
    if not cargo:
        raise RuntimeError("Rust media services need Cargo; install Rust or select --python-bridge")
    manifest = SOURCE / "native" / crate / "Cargo.toml"
    if not manifest.is_file():
        raise RuntimeError("Rust media service source is missing: " + kind)
    result = subprocess.run([cargo, "build", "--release", "--locked", "--offline", "--manifest-path", str(manifest),
                             "--bin", program, "--target-dir", str(target)], capture_output=True, text=True, timeout=300)
    if result.returncode:
        raise RuntimeError("Rust media service build failed before installation: " + kind + ". Rust 1.85+, cached Cargo dependencies and GStreamer development libraries are required.\n" + result.stderr[-3000:])
    binary = target / "release" / program
    check = subprocess.run([str(binary), "--protocol-version"], capture_output=True, text=True, timeout=5)
    if check.returncode or check.stdout.strip() != protocol:
        raise RuntimeError("Built Rust media service failed the protocol or plugin check: " + kind)
    return binary


def build_network(target):
    """Build the NetworkManager service before replacing installed files."""
    cargo = shutil.which("cargo")
    if not cargo:
        raise RuntimeError("Rust Wi-Fi needs Cargo; install Rust or select --python-bridge")
    manifest = SOURCE / "native/network-snapshot/Cargo.toml"
    if not manifest.is_file():
        raise RuntimeError("Rust Wi-Fi service source is missing")
    result = subprocess.run([cargo, "build", "--release", "--locked", "--offline", "--manifest-path", str(manifest),
                             "--bin", "macshell-network", "--target-dir", str(target)], capture_output=True, text=True, timeout=300)
    if result.returncode:
        raise RuntimeError("Rust Wi-Fi build failed before installation. Rust 1.85+, Gio/GLib linker libraries and cached locked Cargo dependencies are required.\n" + result.stderr[-3000:])
    binary = target / "release/macshell-network"
    check = subprocess.run([str(binary), "--protocol-version"], capture_output=True, text=True, timeout=5)
    if check.returncode or check.stdout.strip() != "macshell-network 1":
        raise RuntimeError("Built Rust Wi-Fi service failed the protocol check")
    return binary


def build_niri_input(target):
    cargo = shutil.which("cargo")
    if not cargo:
        raise RuntimeError("Rust niri input needs Cargo; install Rust or select --python-bridge")
    manifest = SOURCE / "native/niri-input/Cargo.toml"
    result = subprocess.run([cargo, "build", "--release", "--locked", "--offline", "--manifest-path", str(manifest), "--bin", "macshell-niri-input", "--target-dir", str(target)], capture_output=True, text=True, timeout=300)
    if result.returncode:
        raise RuntimeError("Rust niri input build failed before installation.\n" + result.stderr[-3000:])
    binary = target / "release/macshell-niri-input"
    check = subprocess.run([str(binary), "--protocol-version"], capture_output=True, text=True, timeout=5)
    if check.returncode or check.stdout.strip() != "macshell-niri-input 1":
        raise RuntimeError("Built Rust niri input failed the protocol check")
    return binary


def build_session_service(target):
    cargo = shutil.which("cargo")
    if not cargo:
        raise RuntimeError("Rust session service needs Cargo; install Rust or select --python-bridge")
    manifest = SOURCE / "native/session-service/Cargo.toml"
    result = subprocess.run([cargo, "build", "--release", "--locked", "--offline", "--manifest-path", str(manifest), "--target-dir", str(target)], capture_output=True, text=True, timeout=300)
    if result.returncode:
        raise RuntimeError("Rust session service build failed before installation.\n" + result.stderr[-3000:])
    return target / "release/macshell-session-service"


def build_currency_fetch(target):
    cargo = shutil.which("cargo")
    if not cargo:
        raise RuntimeError("Rust currency fetch needs Cargo; install Rust or select --python-bridge")
    manifest = SOURCE / "native/currency-fetch/Cargo.toml"
    env = dict(os.environ)
    env.pop("MACSHELL_CURRENCY_TEST_API", None)
    result = subprocess.run([cargo, "build", "--release", "--locked", "--offline", "--manifest-path", str(manifest), "--target-dir", str(target)], capture_output=True, text=True, timeout=300, env=env)
    if result.returncode:
        raise RuntimeError("Rust currency fetch build failed before installation.\n" + result.stderr[-3000:])
    binary = target / "release/macshell-currency-fetch"
    check = subprocess.run([str(binary), "--protocol-version"], capture_output=True, text=True, timeout=5)
    if check.returncode or check.stdout.strip() != "macshell-currency-fetch 1":
        raise RuntimeError("Built Rust currency fetch failed the protocol check")
    return binary


def build_widget_fetch(target):
    cargo = shutil.which("cargo")
    if not cargo:
        raise RuntimeError("Rust widget fetch needs Cargo; install Rust or select --python-bridge")
    env = dict(os.environ)
    env.pop("MACSHELL_WIDGET_TEST_API", None)
    manifest = SOURCE / "native/widget-fetch/Cargo.toml"
    result = subprocess.run([cargo, "build", "--release", "--locked", "--offline", "--manifest-path", str(manifest), "--target-dir", str(target)], capture_output=True, text=True, timeout=300, env=env)
    if result.returncode:
        raise RuntimeError("Rust widget fetch build failed before installation.\n" + result.stderr[-3000:])
    binary = target / "release/macshell-widget-fetch"
    check = subprocess.run([str(binary), "--protocol-version"], capture_output=True, text=True, timeout=5)
    if check.returncode or check.stdout.strip() != "macshell-widget-fetch 1":
        raise RuntimeError("Built Rust widget fetch failed the protocol check")
    return binary


def build_wallpaper_discovery(target):
    cargo = shutil.which("cargo")
    if not cargo:
        raise RuntimeError("Rust wallpaper discovery needs Cargo; install Rust or select --python-bridge")
    manifest = SOURCE / "native/wallpaper-discovery/Cargo.toml"
    result = subprocess.run([cargo, "build", "--release", "--locked", "--offline", "--manifest-path", str(manifest), "--target-dir", str(target)], capture_output=True, text=True, timeout=300)
    if result.returncode:
        raise RuntimeError("Rust wallpaper discovery build failed before installation.\n" + result.stderr[-3000:])
    binary = target / "release/macshell-wallpaper-discovery"
    check = subprocess.run([str(binary), "--protocol-version"], capture_output=True, text=True, timeout=5)
    if check.returncode or check.stdout.strip() != "macshell-wallpaper-discovery 1":
        raise RuntimeError("Built Rust wallpaper discovery failed the protocol check")
    return binary


def build_notes_service(target):
    cargo = shutil.which("cargo")
    if not cargo:
        raise RuntimeError("Rust Notes service needs Cargo; install Rust or select --python-bridge")
    manifest = SOURCE / "native/notes-service/Cargo.toml"
    result = subprocess.run([cargo, "build", "--release", "--locked", "--offline", "--manifest-path", str(manifest), "--target-dir", str(target)], capture_output=True, text=True, timeout=300)
    if result.returncode:
        raise RuntimeError("Rust Notes service build failed before installation. SQLite development libraries and cached Cargo dependencies are required.\n" + result.stderr[-3000:])
    binary = target / "release/macshell-notes-service"
    check = subprocess.run([str(binary), "--protocol-version"], capture_output=True, text=True, timeout=5)
    if check.returncode or check.stdout.strip() != "macshell-notes-service 1":
        raise RuntimeError("Built Rust Notes service failed the protocol check")
    return binary


def build_calendar_service(target):
    cargo = shutil.which("cargo")
    if not cargo:
        raise RuntimeError("Rust Calendar service needs Cargo; install Rust or select --python-bridge")
    manifest = SOURCE / "native/calendar-service/Cargo.toml"
    result = subprocess.run([cargo, "build", "--release", "--locked", "--offline", "--manifest-path", str(manifest), "--target-dir", str(target)], capture_output=True, text=True, timeout=300)
    if result.returncode:
        raise RuntimeError("Rust Calendar service build failed before installation. SQLite development libraries and cached Cargo dependencies are required.\n" + result.stderr[-3000:])
    binary = target / "release/macshell-calendar-service"
    check = subprocess.run([str(binary), "--protocol-version"], capture_output=True, text=True, timeout=5)
    if check.returncode or check.stdout.strip() != "macshell-calendar-service 1":
        raise RuntimeError("Built Rust Calendar service failed the protocol check")
    return binary


def build_reminders_service(target):
    cargo = shutil.which("cargo")
    if not cargo:
        raise RuntimeError("Rust Reminders service needs Cargo; install Rust or select --python-bridge")
    manifest = SOURCE / "native/reminders-service/Cargo.toml"
    result = subprocess.run([cargo, "build", "--release", "--locked", "--offline", "--manifest-path", str(manifest), "--target-dir", str(target)], capture_output=True, text=True, timeout=300)
    if result.returncode:
        raise RuntimeError("Rust Reminders service build failed before installation. SQLite development libraries and cached Cargo dependencies are required.\n" + result.stderr[-3000:])
    binary = target / "release/macshell-reminders-service"
    check = subprocess.run([str(binary), "--protocol-version"], capture_output=True, text=True, timeout=5)
    if check.returncode or check.stdout.strip() != "macshell-reminders-service 1":
        raise RuntimeError("Built Rust Reminders service failed the protocol check")
    return binary


def build_clock_service(target):
    cargo = shutil.which("cargo")
    if not cargo:
        raise RuntimeError("Rust Clock service needs Cargo; install Rust or select --python-bridge")
    manifest = SOURCE / "native/clock-core/Cargo.toml"
    result = subprocess.run([cargo, "build", "--release", "--locked", "--offline", "--manifest-path", str(manifest), "--target-dir", str(target), "--bin", "clock-service-prototype", "--bin", "clock-audio-worker", "--bin", "clock-sound-import"], capture_output=True, text=True, timeout=300)
    if result.returncode:
        raise RuntimeError("Rust Clock service build failed before installation.\n" + result.stderr[-3000:])
    binaries = {name: target / "release" / name for name in ("clock-service-prototype", "clock-audio-worker", "clock-sound-import")}
    check = subprocess.run([str(binaries["clock-service-prototype"]), "--protocol-version"], capture_output=True, text=True, timeout=5)
    if check.returncode or check.stdout.strip() != "macshell-clock-service 1":
        raise RuntimeError("Built Rust Clock service failed the protocol check")
    check = subprocess.run([str(binaries["clock-sound-import"]), "--protocol-version"], capture_output=True, text=True, timeout=5)
    if check.returncode or check.stdout.strip() != "macshell-clock-import 1":
        raise RuntimeError("Built Rust Clock sound importer failed the protocol check")
    return binaries


def build_screen_mirroring(target):
    cargo = shutil.which("cargo")
    if not cargo:
        raise RuntimeError("Rust Screen Mirroring needs Cargo; install Rust or select --python-bridge")
    manifest = SOURCE / "native/screen-mirroring/Cargo.toml"
    result = subprocess.run([cargo, "build", "--release", "--locked", "--offline", "--manifest-path", str(manifest), "--target-dir", str(target)], capture_output=True, text=True, timeout=300)
    if result.returncode:
        raise RuntimeError("Rust Screen Mirroring build failed before installation.\n" + result.stderr[-3000:])
    binary = target / "release/macshell-screen-mirroring"
    check = subprocess.run([str(binary), "--protocol-version"], capture_output=True, text=True, timeout=5)
    if check.returncode or check.stdout.strip() != "macshell-screen-mirroring 1":
        raise RuntimeError("Built Rust Screen Mirroring failed the protocol check")
    return binary


def build_airdrop_service(target):
    cargo = shutil.which("cargo")
    if not cargo:
        raise RuntimeError("Rust AirDrop needs Cargo; install Rust or select --python-bridge")
    manifest = SOURCE / "native/airdrop-service/Cargo.toml"
    result = subprocess.run([cargo, "build", "--release", "--locked", "--offline", "--manifest-path", str(manifest), "--target-dir", str(target)], capture_output=True, text=True, timeout=300)
    if result.returncode:
        raise RuntimeError("Rust AirDrop build failed before installation.\n" + result.stderr[-3000:])
    binary = target / "release/macshell-airdrop-service"
    check = subprocess.run([str(binary), "--protocol-version"], capture_output=True, text=True, timeout=5)
    if check.returncode or check.stdout.strip() != "macshell-airdrop-service 1":
        raise RuntimeError("Built Rust AirDrop failed the protocol check")
    return binary


def build_biometric_probe(target):
    """Build the read-only fprintd discovery helper before installation."""
    cargo = shutil.which("cargo")
    if not cargo:
        raise RuntimeError("Rust biometric discovery needs Cargo; install Rust or select --python-bridge")
    manifest = SOURCE / "native/biometric-probe/Cargo.toml"
    result = subprocess.run([cargo, "build", "--release", "--locked", "--offline", "--manifest-path", str(manifest), "--target-dir", str(target)], capture_output=True, text=True, timeout=300)
    if result.returncode:
        raise RuntimeError("Rust biometric discovery build failed before installation. Rust 1.85+, Gio/GLib linker libraries and cached locked Cargo dependencies are required.\n" + result.stderr[-3000:])
    binary = target / "release/macshell-biometric-probe"
    check = subprocess.run([str(binary), "--protocol-version"], capture_output=True, text=True, timeout=5)
    if check.returncode or check.stdout.strip() != "macshell-biometric-probe 1":
        raise RuntimeError("Built Rust biometric discovery failed the protocol check")
    operation = target / "release/fingerprint-operation"
    check = subprocess.run([str(operation), "--protocol-version"], capture_output=True, text=True, timeout=5)
    if check.returncode or check.stdout.strip() != "macshell-fingerprint-operation 1":
        raise RuntimeError("Built Rust fingerprint operation failed the protocol check")
    return binary


def build_update_service(target):
    cargo = shutil.which("cargo")
    if not cargo:
        raise RuntimeError("Rust update service needs Cargo; install Rust or select --python-bridge")
    manifest = SOURCE / "native/update-service/Cargo.toml"
    result = subprocess.run([cargo, "build", "--release", "--locked", "--offline", "--manifest-path", str(manifest), "--target-dir", str(target)], capture_output=True, text=True, timeout=300)
    if result.returncode:
        raise RuntimeError("Rust update service build failed before installation. Cached locked Cargo dependencies are required.\n" + result.stderr[-3000:])
    binary = target / "release/macshell-update-service"
    check = subprocess.run([str(binary), "--protocol-version"], capture_output=True, text=True, timeout=5)
    if check.returncode or check.stdout.strip() != "macshell-update-service 1":
        raise RuntimeError("Built Rust update service failed the protocol check")
    return binary


def install(activate=False, session=False, rust_bridge=None):
    if os.geteuid() == 0:
        raise RuntimeError("Run as your desktop user, without sudo.")
    with install_guard():
        if session_active():
            raise RuntimeError("Log out of the MacShell session before installing or updating it")
        install_unlocked(activate, session, rust_bridge)


def install_unlocked(activate=False, session=False, rust_bridge=None):
    if not activate and not session and NIRI.is_file() and NIRI.read_text().startswith("// Original config snapshot:"):
        raise RuntimeError("MacShell is already active. Use --activate to update it with session recovery.")
    if activate or session:
        runtime_check()
    with tempfile.TemporaryDirectory(prefix="macshell-install-") as temporary:
        # Rust is the default for fresh installs and updates; the explicit legacy
        # option remains available while other services still depend on Python.
        use_rust = rust_bridge is not False
        rust_binary = build_niri_bridge(Path(temporary) / "rust-build") if use_rust else None
        clock_binary = build_boot_clock(Path(temporary) / "clock-build") if use_rust else None
        stats_binary = build_system_stats(Path(temporary) / "stats-build") if use_rust else None
        night_binary = build_night_shift(Path(temporary) / "night-build") if use_rust else None
        timed_binary = build_timed_modes(Path(temporary) / "timed-build") if use_rust else None
        activity_binary = build_activity_preferences(Path(temporary) / "activity-build") if use_rust else None
        bar_binary = build_bar_preferences(Path(temporary) / "bar-build") if use_rust else None
        widget_binary = build_widget_preferences(Path(temporary) / "widget-build") if use_rust else None
        locale_binary = build_locale_preferences(Path(temporary) / "locale-build") if use_rust else None
        blur_binary = build_native_blur(Path(temporary) / "blur-build") if use_rust else None
        preflight_binary = build_session_preflight(Path(temporary) / "preflight-build") if use_rust else None
        power_binary = build_power_profiles(Path(temporary) / "power-build") if use_rust else None
        color_binary = build_niri_color(Path(temporary) / "color-build") if use_rust else None
        bluetooth_binary = build_bluetooth(Path(temporary) / "bluetooth-build") if use_rust else None
        capture_binary = build_media_service(Path(temporary) / "capture-build", "capture") if use_rust else None
        recording_binary = build_media_service(Path(temporary) / "recording-build", "recording") if use_rust else None
        network_binary = build_network(Path(temporary) / "network-build") if use_rust else None
        input_binary = build_niri_input(Path(temporary) / "input-build") if use_rust else None
        session_binary = build_session_service(Path(temporary) / "session-build") if use_rust else None
        currency_binary = build_currency_fetch(Path(temporary) / "currency-build") if use_rust else None
        widget_fetch_binary = build_widget_fetch(Path(temporary) / "widget-fetch-build") if use_rust else None
        wallpaper_binary = build_wallpaper_discovery(Path(temporary) / "wallpaper-build") if use_rust else None
        notes_binary = build_notes_service(Path(temporary) / "notes-build") if use_rust else None
        calendar_binary = build_calendar_service(Path(temporary) / "calendar-build") if use_rust else None
        reminders_binary = build_reminders_service(Path(temporary) / "reminders-build") if use_rust else None
        clock_binaries = build_clock_service(Path(temporary) / "clock-build") if use_rust else None
        mirroring_binary = build_screen_mirroring(Path(temporary) / "mirroring-build") if use_rust else None
        airdrop_binary = build_airdrop_service(Path(temporary) / "airdrop-build") if use_rust else None
        biometric_binary = build_biometric_probe(Path(temporary) / "biometric-build") if use_rust else None
        update_binary = build_update_service(Path(temporary) / "update-build") if use_rust else None
        staged = Path(temporary) / "niri"
        previous_port = activate and NIRI.is_file() and NIRI.read_text().startswith("// Original config snapshot:")
        if activate or session:
            previous_shell = prepare_niri(staged)
        targets = [SHELL, LOCK, BIN / "macshell-niri", BIN / "maclock-niri", PROFILE] + ([NIRI] if activate else [])
        if session:
            targets += [SESSION_UNIT, SHELL_UNIT, BIN / "niri-macshell-session", DATA / "session"]
        directory, manifest = snapshot(targets)
        if activate:
            manifest["previous_shell"] = "MacShell-niri" if previous_port else "noctalia-shell" if previous_shell else None
        previous_stopped = False
        try:
            if previous_port:
                previous_stopped = stop_shell("MacShell-niri")
            for source, destination in ((SOURCE / "MacShell", SHELL), (SOURCE / "MacLock", LOCK)):
                remove(destination)
                shutil.copytree(source, destination, ignore=shutil.ignore_patterns("__pycache__", "*.pyc", "niri-bridge-rust", "boot-clock-rust", "system-stats-rust", "night-shift-rust", "timed-modes-rust", "activity-preferences-rust", "bar-preferences-rust", "widget-preferences-rust", "locale-preferences-rust", "native-blur-rust", "session-preflight-rust", "power-profiles-rust", "niri-color-rust", "bluetooth-service-rust", "capture-service-rust", "recording-service-rust", "network-service-rust", "niri-input-rust", "biometric-probe-rust", "update-service-rust", "desktop-source-rust", "preview-rust"))
            (SHELL / "niri-input-service.sh").chmod(0o755)
            shutil.copy2(SOURCE / "MacShell/session-service.sh", SHELL / "session-service.sh")
            (SHELL / "session-service.sh").chmod(0o755)
            if rust_binary:
                shutil.copy2(airdrop_binary, SHELL / "airdrop-service-rust")
                (SHELL / "airdrop-service-rust").chmod(0o755)
                shutil.copy2(biometric_binary, SHELL / "biometric-probe-rust")
                (SHELL / "biometric-probe-rust").chmod(0o755)
                shutil.copy2(biometric_binary.parent / "fingerprint-operation", SHELL / "fingerprint-operation-rust")
                (SHELL / "fingerprint-operation-rust").chmod(0o755)
                shutil.copy2(update_binary, SHELL / "update-service-rust")
                (SHELL / "update-service-rust").chmod(0o755)
                shutil.copy2(mirroring_binary, SHELL / "screen-mirroring-service-rust")
                (SHELL / "screen-mirroring-service-rust").chmod(0o755)
                shutil.copy2(rust_binary, SHELL / "niri-bridge-rust")
                (SHELL / "niri-bridge-rust").chmod(0o755)
                shutil.copy2(clock_binary, LOCK / "boot-clock-rust")
                (LOCK / "boot-clock-rust").chmod(0o755)
                shutil.copy2(clock_binary, SHELL / "boot-clock-rust")
                (SHELL / "boot-clock-rust").chmod(0o755)
                shutil.copy2(stats_binary, SHELL / "system-stats-rust")
                (SHELL / "system-stats-rust").chmod(0o755)
                shutil.copy2(night_binary, SHELL / "night-shift-rust")
                (SHELL / "night-shift-rust").chmod(0o755)
                shutil.copy2(timed_binary, SHELL / "timed-modes-rust")
                (SHELL / "timed-modes-rust").chmod(0o755)
                shutil.copy2(activity_binary, SHELL / "activity-preferences-rust")
                (SHELL / "activity-preferences-rust").chmod(0o755)
                shutil.copy2(bar_binary, SHELL / "bar-preferences-rust")
                (SHELL / "bar-preferences-rust").chmod(0o755)
                shutil.copy2(widget_binary, SHELL / "widget-preferences-rust")
                (SHELL / "widget-preferences-rust").chmod(0o755)
                shutil.copy2(locale_binary, SHELL / "locale-preferences-rust")
                (SHELL / "locale-preferences-rust").chmod(0o755)
                shutil.copy2(blur_binary, SHELL / "native-blur-rust")
                (SHELL / "native-blur-rust").chmod(0o755)
                shutil.copy2(preflight_binary, SHELL / "session-preflight-rust")
                (SHELL / "session-preflight-rust").chmod(0o755)
                shutil.copy2(power_binary, SHELL / "power-profiles-rust")
                (SHELL / "power-profiles-rust").chmod(0o755)
                shutil.copy2(color_binary, SHELL / "niri-color-rust")
                (SHELL / "niri-color-rust").chmod(0o755)
                shutil.copy2(bluetooth_binary, SHELL / "bluetooth-service-rust")
                (SHELL / "bluetooth-service-rust").chmod(0o755)
                shutil.copy2(capture_binary, SHELL / "capture-service-rust")
                (SHELL / "capture-service-rust").chmod(0o755)
                shutil.copy2(recording_binary, SHELL / "recording-service-rust")
                (SHELL / "recording-service-rust").chmod(0o755)
                shutil.copy2(network_binary, SHELL / "network-service-rust")
                (SHELL / "network-service-rust").chmod(0o755)
                shutil.copy2(input_binary, SHELL / "niri-input-rust")
                (SHELL / "niri-input-rust").chmod(0o755)
                shutil.copy2(session_binary, SHELL / "session-service-rust")
                (SHELL / "session-service-rust").chmod(0o755)
                shutil.copy2(currency_binary, SHELL / "currency-fetch-rust")
                (SHELL / "currency-fetch-rust").chmod(0o755)
                shutil.copy2(widget_fetch_binary, SHELL / "widget-fetch-rust")
                (SHELL / "widget-fetch-rust").chmod(0o755)
                shutil.copy2(wallpaper_binary, SHELL / "wallpaper-discovery-rust")
                (SHELL / "wallpaper-discovery-rust").chmod(0o755)
                shutil.copy2(notes_binary, SHELL / "notes-service-rust")
                (SHELL / "notes-service-rust").chmod(0o755)
                shutil.copy2(calendar_binary, SHELL / "calendar-service-rust")
                (SHELL / "calendar-service-rust").chmod(0o755)
                shutil.copy2(reminders_binary, SHELL / "reminders-service-rust")
                (SHELL / "reminders-service-rust").chmod(0o755)
                for name, binary in clock_binaries.items():
                    shutil.copy2(binary, SHELL / (name + "-rust"))
                    (SHELL / (name + "-rust")).chmod(0o755)
            shutil.copy2(SOURCE / "VERSION", SHELL / "VERSION")
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
                session_files(locale_binary, preflight_binary)
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
                    previous_stopped = stop_shell("noctalia-shell") or previous_stopped
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
            if session:
                subprocess.run(["systemctl", "--user", "daemon-reload"], capture_output=True)
            if manifest.get("activated"):
                subprocess.run(["niri", "msg", "action", "load-config-file"], capture_output=True)
            if previous_stopped:
                start_previous(manifest.get("previous_shell"))
            raise
    print("Installed MacShell-niri and MacLock-niri.\nBackup:", directory)
    print("niri bridge and migrated system services:", "Rust" if use_rust else "Python (transition)")
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
    bridge = parser.add_mutually_exclusive_group()
    bridge.add_argument("--rust-bridge", action="store_true", help="Build Rust components from cached Cargo dependencies (default)")
    bridge.add_argument("--python-bridge", action="store_true", help="Use the legacy Python implementations during the transition")
    args = parser.parse_args()
    if args.activate and args.session:
        parser.error("Choose either --session or --activate")
    if args.rollback and (args.rust_bridge or args.python_bridge):
        parser.error("Bridge selection does not apply to rollback")
    if args.check:
        ok = doctor()
        if not args.python_bridge:
            available = bool(shutil.which("cargo"))
            print("OK: Cargo" if available else "ERROR: Rust bridge needs Cargo")
            ok &= available
        return 0 if ok else 1
    if args.dry_run:
        print("Shell:", SHELL, "\nLock:", LOCK, "\nSettings:", PROFILE / "settings", "\nLaunchers:", BIN, "\nBackups:", DATA / "backups")
        use_rust = not args.python_bridge
        print("niri bridge and migrated system services:", "Rust (build from cached dependencies)" if use_rust else "Python (transition)")
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
        with install_guard():
            if session_active():
                raise RuntimeError("Log out of the MacShell session before rolling back")
            stopped = stop_shell("MacShell-niri") if manifest["activated"] else False
            try:
                restore(directory, manifest, args.force)
                if manifest.get("session_only"):
                    subprocess.run(["systemctl", "--user", "daemon-reload"], check=True, capture_output=True)
                if manifest["activated"]:
                    subprocess.run(["niri", "msg", "action", "load-config-file"], check=True, capture_output=True)
                    start_previous(manifest.get("previous_shell"))
            except Exception:
                if stopped:
                    start_previous("MacShell-niri")
                raise
        print("Restored:", directory, "\nPost-install files were preserved in its after/ directory.")
        return 0
    selection = True if args.rust_bridge else False if args.python_bridge else None
    install(args.activate, args.session, selection)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print("ERROR:", error, file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError):
            print(error.stderr or "", file=sys.stderr)
        sys.exit(1)

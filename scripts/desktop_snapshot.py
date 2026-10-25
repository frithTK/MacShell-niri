#!/usr/bin/env python3
"""Private desktop snapshots with checksums and a standalone restore command."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import uuid

SOURCE = Path(__file__).resolve().parent.parent
USER_PATHS = [
    ".config/niri", ".config/noctalia", ".config/quickshell", ".cache/noctalia",
    ".config/macshell-niri", ".config/systemd/user/niri.service.d",
    ".config/systemd/user/niri-macshell.service",
    ".config/environment.d", ".config/qt6ct", ".config/qt5ct", ".config/Kvantum",
    ".config/gtk-3.0", ".config/gtk-4.0", ".config/kdeglobals", ".dmrc",
    ".local/bin/macshell-niri", ".local/bin/maclock-niri", ".local/bin/niri-macshell-session",
]
SYSTEM_PATHS = [
    "/etc/sddm.conf", "/etc/sddm.conf.d", "/usr/share/wayland-sessions/niri.desktop",
    "/usr/lib/systemd/user/niri.service", "/usr/bin/niri-session",
    "/usr/local/share/wayland-sessions/niri-macshell.desktop",
    "/usr/local/bin/niri-macshell-session",
]


def copy(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if source.is_symlink():
        destination.symlink_to(os.readlink(source))
    elif source.is_dir():
        shutil.copytree(source, destination, symlinks=True, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    else:
        shutil.copy2(source, destination)


def checksums(directory):
    result = {}
    for path in sorted(directory.rglob("*")):
        if path.is_file() and not path.is_symlink() and path.name != "checksums.json":
            result[str(path.relative_to(directory))] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


def verify(directory):
    expected = json.loads((directory / "checksums.json").read_text())
    for relative, value in expected.items():
        path = directory / relative
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != value:
            raise RuntimeError("Snapshot checksum mismatch: " + relative)
    return len(expected)


def create(home, root=None):
    root = root or home / ".local/share/macshell-niri/snapshots"
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]
    directory = root / stamp
    directory.mkdir(parents=True, mode=0o700)
    directory.chmod(0o700)
    entries = []
    for relative in USER_PATHS:
        path = home / relative
        exists = path.exists() or path.is_symlink()
        if exists:
            copy(path, directory / "home" / relative)
        entries.append({"relative": relative, "existed": exists})
    system = []
    for name in SYSTEM_PATHS:
        path = Path(name)
        exists = path.exists() or path.is_symlink()
        if exists:
            copy(path, directory / "system" / name.lstrip("/"))
        system.append({"path": name, "existed": exists})
    if (SOURCE / ".git").exists():
        copy(SOURCE, directory / "source/MacShell")
    for command, name in ((["pacman", "-Q"], "packages.txt"), (["niri", "msg", "-j", "outputs"], "outputs.json"), (["niri", "msg", "-j", "workspaces"], "workspaces.json")):
        result = subprocess.run(command, capture_output=True, text=True)
        (directory / name).write_text(result.stdout if result.returncode == 0 else result.stderr)
    manifest = {"created": stamp, "home": str(home), "entries": entries, "system": system,
                "scope": "Desktop configuration and port sources; not a full disk or running-application snapshot."}
    (directory / "manifest.json").write_text(json.dumps(manifest, indent=2))
    shutil.copy2(__file__, directory / "restore.py")
    (directory / "restore.sh").write_text('#!/usr/bin/env bash\nset -euo pipefail\nsnapshot_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)\nexec python3 "$snapshot_dir/restore.py" --restore "$snapshot_dir" "$@"\n')
    (directory / "restore.sh").chmod(0o700)
    (directory / "README.txt").write_text("Backup of niri, Noctalia, related theme settings, package inventory and MacShell source.\nVerify: python3 restore.py --verify .\nRestore user configuration: bash restore.sh\nCurrent files are first saved under pre-restore-*/. System files are reference copies only.\nIf a MacShell SDDM entry was registered, remove it using the generated register-session.sh --remove command.\nThis is not a full disk snapshot.\n")
    (directory / "checksums.json").write_text(json.dumps(checksums(directory), indent=2))
    count = verify(directory)
    (root / "latest").write_text(str(directory))
    print(f"Snapshot: {directory}\nVerified files: {count}\nRestore: bash {directory}/restore.sh")
    return directory


def restore(directory):
    verify(directory)
    manifest = json.loads((directory / "manifest.json").read_text())
    home = Path(manifest["home"])
    if home.resolve() != Path.home().resolve() or os.geteuid() == 0:
        raise RuntimeError("Run restore as the desktop user, without sudo.")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:6]
    recovery = directory / ("pre-restore-" + stamp)
    recovery.mkdir(mode=0o700)
    # Save every destination before replacing any of them.
    for entry in manifest["entries"]:
        path = home / entry["relative"]
        if path.exists() or path.is_symlink():
            copy(path, recovery / entry["relative"])
    for entry in manifest["entries"]:
        path = home / entry["relative"]
        if path.is_symlink() or path.is_file():
            path.unlink()
        elif path.is_dir():
            shutil.rmtree(path)
        if entry["existed"]:
            copy(directory / "home" / entry["relative"], path)
    print("Restored desktop configuration. Current files preserved at:", recovery)
    print("Log out and select the original Niri session. System files and running processes were not changed.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--restore", type=Path)
    group.add_argument("--verify", type=Path)
    arguments = parser.parse_args()
    try:
        if arguments.restore:
            restore(arguments.restore.resolve())
        elif arguments.verify:
            print("Verified files:", verify(arguments.verify.resolve()))
        else:
            create(Path.home())
    except (OSError, RuntimeError, ValueError) as error:
        print("ERROR:", error, file=sys.stderr)
        sys.exit(1)

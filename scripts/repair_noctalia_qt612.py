#!/usr/bin/env python3
"""Work around Qt 6.12 Color shadowing in a backed-up user copy of Noctalia."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shutil
import sys
import uuid


def pin_imports(directory):
    changed = 0
    for path in directory.rglob("*.qml"):
        if path.is_symlink():
            raise RuntimeError("Refusing to edit a QML symlink: " + str(path))
        original = path.read_text()
        # Hide the QtQuick.Color type introduced in 6.12. Existing explicit
        # import versions and all application settings remain as they were.
        updated = re.sub(r"^(import[ \t]+QtQuick)([ \t]*(?://[^\n]*)?)$", r"\1 6.11\2", original, flags=re.MULTILINE)
        if original != updated:
            path.write_text(updated)
            changed += 1
    return changed


def repair(config, data, apply=False):
    target = config / "quickshell/noctalia-shell"
    candidates = [target] + [Path(p) / "quickshell/noctalia-shell" for p in os.environ.get("XDG_CONFIG_DIRS", "/etc/xdg").split(":") if p]
    source = next((p for p in candidates if (p / "shell.qml").is_file()), None)
    if source is None or not (source / "Commons/Color.qml").is_file():
        raise RuntimeError("Noctalia with Commons/Color.qml was not found.")
    plugins = config / "noctalia/plugins"
    if target.is_symlink() or plugins.is_symlink():
        raise RuntimeError("Shell/plugin directory is a symlink; inspect it before applying the workaround.")
    print("Source:", source, "\nUser shell:", target, "\nPlugins:", plugins)
    if not apply:
        print("Dry run. Use --apply to back up these paths and pin QtQuick imports to 6.11.")
        return None
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]
    backup = data / "noctalia-qt612-repairs" / stamp
    backup.mkdir(parents=True, mode=0o700)
    entries = []
    for index, path in enumerate((target, plugins)):
        existed = path.exists()
        entries.append({"path": str(path), "existed": existed, "index": index})
        if existed:
            shutil.copytree(path, backup / str(index), symlinks=True)
    (backup / "manifest.json").write_text(json.dumps(entries, indent=2))
    try:
        if not target.exists():
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(source, target, symlinks=False)
        changed = pin_imports(target)
        if plugins.exists():
            changed += pin_imports(plugins)
    except Exception:
        restore(backup)
        raise
    print(f"Patched QML files: {changed}\nBackup: {backup}")
    print("Log out and select the original Niri session to load the repaired shell.")
    print("Undo: python3", Path(__file__).resolve(), "--restore", backup)
    return backup


def restore(backup):
    entries = json.loads((backup / "manifest.json").read_text())
    # Preserve edits made since the workaround before restoring anything.
    recovery = backup / ("after-" + uuid.uuid4().hex[:8])
    recovery.mkdir(mode=0o700)
    for entry in entries:
        path = Path(entry["path"])
        if path.exists() or path.is_symlink():
            shutil.move(str(path), recovery / str(entry["index"]))
        if entry["existed"]:
            shutil.copytree(backup / str(entry["index"]), path, symlinks=True)
    print("Restored previous shell files. Later files preserved at:", recovery)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--apply", action="store_true")
    mode.add_argument("--restore", type=Path)
    args = parser.parse_args()
    try:
        if os.geteuid() == 0:
            raise RuntimeError("Run as the desktop user, without sudo.")
        if args.restore:
            restore(args.restore)
        else:
            repair(Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")),
                   Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "macshell-niri", args.apply)
    except (OSError, RuntimeError, ValueError) as error:
        print("ERROR:", error, file=sys.stderr)
        sys.exit(1)

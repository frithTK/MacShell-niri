#!/usr/bin/env python3
"""Install selected MacShell fallback icons as non-overwriting user overrides."""
import argparse
import hashlib
import os
from pathlib import Path
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ICON_DIR = ROOT / 'MacShell/assets/app-icons'
ICONS = {
    'agentdvr': 'macshell-agent-dvr.svg',
    'lstopo': 'macshell-hwloc.svg',
    'links': 'macshell-links.svg',
    'protontricks': 'macshell-protontricks.svg',
}


def desktop_override(content, icon):
    lines = content.splitlines(keepends=True)
    in_entry = False
    changes = 0
    output = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith('[') and stripped.endswith(']'):
            in_entry = stripped == '[Desktop Entry]'
        if in_entry and line.startswith('Icon='):
            output.append('Icon=' + str(icon) + '\n')
            changes += 1
        else:
            output.append(line)
    if changes != 1:
        raise ValueError('Expected exactly one Icon in the desktop entry')
    return ''.join(output).encode('utf-8')


def create_new(path, data):
    """Publish a complete file atomically, without replacing existing data."""
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temp_name = tempfile.mkstemp(prefix='.macshell-icon-', dir=path.parent)
    temp = Path(temp_name)
    try:
        with os.fdopen(descriptor, 'wb') as output:
            output.write(data)
            output.flush()
            os.fchmod(output.fileno(), 0o644)
            os.fsync(output.fileno())
        os.link(temp, path)
    finally:
        temp.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', action='append', choices=sorted(ICONS), required=True)
    parser.add_argument('--data-home', type=Path, default=Path(os.environ.get('XDG_DATA_HOME') or Path.home() / '.local/share'))
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    data_home = args.data_home.expanduser().absolute()
    if '\n' in str(data_home) or '\r' in str(data_home):
        parser.error('data-home cannot contain line breaks')
    apps = list(dict.fromkeys(args.app))
    plan = []
    for app in apps:
        source = Path('/usr/share/applications') / (app + '.desktop')
        svg = ICON_DIR / ICONS[app]
        destination_icon = data_home / 'icons/hicolor/scalable/apps' / svg.name
        destination_desktop = data_home / 'applications' / (app + '.desktop')
        content = desktop_override(source.read_text(encoding='utf-8'), destination_icon)
        plan.extend(((destination_icon, svg.read_bytes()), (destination_desktop, content)))
    existing = [path for path, _ in plan if os.path.lexists(path)]
    if existing:
        raise FileExistsError('Refusing to overwrite existing files: ' + ', '.join(map(str, existing)))
    for path, data in plan:
        print(('INSTALL ' if args.apply else 'PLAN ') + str(path) + ' sha256=' + hashlib.sha256(data).hexdigest())
    if not args.apply:
        return
    created = []
    try:
        # Publish icons first, so every visible desktop override has an existing icon.
        for path, data in plan[::2] + plan[1::2]:
            create_new(path, data)
            created.append(path)
    except BaseException:
        for path in reversed(created):
            path.unlink(missing_ok=True)
        raise
    print('Installed user icon overrides for: ' + ', '.join(apps))


if __name__ == '__main__':
    main()

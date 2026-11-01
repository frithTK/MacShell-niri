#!/usr/bin/env python3
"""Install missing theme names used by an already-running MacShell session."""
import os
from pathlib import Path

root = Path(__file__).resolve().parents[1]
icons = root / 'MacShell/assets/app-icons'
target = Path(os.environ.get('XDG_DATA_HOME') or Path.home() / '.local/share') / 'icons/hicolor/scalable/apps'
target.mkdir(parents=True, exist_ok=True)
for name, source in [('accessories-calculator.svg', 'macshell-calculator.svg'),
                     ('preferences-system-time.svg', 'macshell-clock.svg')]:
    path = target / name
    try:
        with path.open('xb') as out:
            out.write((icons / source).read_bytes())
    except FileExistsError:
        print(f'Preserved existing icon: {path}')
    else:
        print(f'Installed: {path}')

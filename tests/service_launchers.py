"""Point copied launchers at Python services for comparison QML tests.

Production launchers require a compatible Rust binary and never invoke
Python. Isolated QML client/standalone checks still drive the Python
modules in a temporary copy of MacShell.
"""
import shutil
from pathlib import Path

LAUNCHERS = {
    'notes-service.sh': 'notes_service.py',
    'calendar-service.sh': 'calendar_service.py',
    'reminders-service.sh': 'reminders_service.py',
    'clock-service.sh': 'clock_service.py',
    'clock-sound-import.sh': 'clock_sound_import.py',
    'boot-clock.sh': 'boot_clock.py',
}


def point_copied_launchers_at_python(shell: Path, names=None):
    selected = LAUNCHERS if names is None else {name: LAUNCHERS[name] for name in names}
    for launcher, script in selected.items():
        path = shell / launcher
        if not path.is_file():
            continue
        path.write_text(
            '#!/bin/sh\n'
            'directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)\n'
            f'exec python3 "$directory/{script}" "$@"\n'
        )
        path.chmod(0o755)


def copy_macshell_with_python_launchers(source: Path, destination: Path, **copytree):
    shutil.copytree(source, destination, **copytree)
    point_copied_launchers_at_python(destination)
    return destination

#!/usr/bin/env bash
set -euo pipefail
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$source_dir"
test_python=${MACSHELL_TEST_PYTHON:-python3}
"$test_python" -m unittest discover -s tests -v
"$test_python" -m py_compile MacShell/*.py scripts/*.py
for script in install.sh MacShell/macshell-setwall.sh MacShell/macshell-update scripts/*.sh; do
    bash -n "$script"
done
for script in MacLock/lock-via-ipc.sh scripts/session-entry.sh; do
    sh -n "$script"
done
desktop-file-validate config/niri-macshell.desktop
printf '%s\n' 'Python regressions, source syntax and desktop-entry checks passed.'

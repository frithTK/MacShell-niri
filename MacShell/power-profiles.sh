#!/bin/sh
set -eu
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$directory/power-profiles-rust"
if [ -x "$binary" ] && [ "$(timeout 3 "$binary" --protocol-version 2>/dev/null || :)" = "macshell-power-profiles 1" ]; then
    exec "$binary" "$@"
fi
exec python3 -u "$directory/power_control.py" "$@"

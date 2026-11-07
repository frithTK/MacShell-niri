#!/bin/sh
set -eu
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$directory/night-shift-rust"
if [ -x "$binary" ] && [ "$(timeout 3 "$binary" --protocol-version 2>/dev/null || :)" = "macshell-night-shift 1" ]; then
    exec "$binary" "$@"
fi
exec python3 -u "$directory/night_shift.py" "$@"

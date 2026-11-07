#!/bin/sh
set -eu
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$directory/timed-modes-rust"
if [ -x "$binary" ] && [ "$(timeout 3 "$binary" --protocol-version 2>/dev/null || :)" = "macshell-timed-modes 1" ]; then
    exec "$binary" "$@"
fi
exec python3 -u "$directory/timed_modes.py" "$@"

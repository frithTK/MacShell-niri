#!/bin/sh
set -eu
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$directory/system-stats-rust"
if [ -x "$binary" ] && [ "$(timeout 3 "$binary" --protocol-version 2>/dev/null || :)" = "macshell-system-stats 1" ]; then
    exec "$binary" "$@"
fi
exec python3 -u "$directory/system_stats.py" "$@"

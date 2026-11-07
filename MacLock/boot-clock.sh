#!/bin/sh
set -eu
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$directory/boot-clock-rust"
if [ -x "$binary" ] && [ "$(timeout 3 "$binary" --protocol-version 2>/dev/null || :)" = "macshell-boot-clock 1" ]; then
    exec "$binary" "$@"
fi
exec python3 -u "$directory/boot_clock.py" "$@"

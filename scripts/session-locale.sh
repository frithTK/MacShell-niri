#!/bin/sh
set -eu
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$directory/locale-preferences-rust"
if [ -x "$binary" ] && [ "$(timeout 3 "$binary" --protocol-version 2>/dev/null || :)" = "macshell-locale-preferences 1" ]; then
    exec "$binary" --session
fi
exec python3 "$directory/session-locale.py"

#!/bin/sh
set -eu
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$directory/session-preflight-rust"
if [ -x "$binary" ] && [ "$(timeout 3 "$binary" --protocol-version 2>/dev/null || :)" = "macshell-session-preflight 1" ]; then
    exec "$binary" "$@"
fi
echo 'Session preflight Rust helper is missing or incompatible' >&2
exit 1

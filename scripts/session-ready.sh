#!/bin/sh
set -eu
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$directory/session-preflight-rust"
if [ -x "$binary" ] && [ "$(timeout 3 "$binary" --ready-protocol-version 2>/dev/null || :)" = "macshell-session-ready 1" ]; then
    exec "$binary" --ready "$@"
fi
echo 'Session readiness Rust helper is missing or incompatible' >&2
exit 1

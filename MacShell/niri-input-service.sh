#!/bin/sh
set -eu
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$directory/niri-input-rust"
if [ -x "$binary" ] && [ "$(timeout 3 "$binary" --protocol-version 2>/dev/null || true)" = "macshell-niri-input 1" ]; then
    exec "$binary" "$@"
fi
echo 'niri-input Rust service is missing or incompatible' >&2
exit 1

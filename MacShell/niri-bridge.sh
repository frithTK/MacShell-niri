#!/bin/sh
# Select one bridge before it starts. A running bridge is never replaced in-place.
set -eu
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$directory/niri-bridge-rust"
backend=${MACSHELL_NIRI_BRIDGE_BACKEND:-auto}
case "$backend" in
    auto|rust)
        if [ -x "$binary" ] && [ "$(timeout 3 "$binary" --protocol-version 2>/dev/null || true)" = 'macshell-niri-bridge 1' ]; then
            exec "$binary"
        fi
        if [ "$backend" = rust ]; then
            echo 'Rust niri bridge is missing or incompatible' >&2
            exit 1
        fi
        if [ -e "$binary" ]; then
            echo '[niri] Rust bridge unavailable or incompatible; using Python bridge' >&2
        fi
        ;;
    python) ;;
    *) echo 'Invalid niri bridge selection' >&2; exit 1 ;;
esac
exec python3 -u "$directory/niri_ipc.py"

#!/bin/sh
set -eu
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$directory/niri-input-rust"
if [ -x "$binary" ] && [ "$(timeout 3 "$binary" --protocol-version 2>/dev/null || true)" = "macshell-niri-input 1" ]; then
    exec "$binary" "$@"
fi
[ ! -e "$directory/.macshell-rust-only" ] && [ ! -L "$directory/.macshell-rust-only" ] || { echo 'niri-input Rust service is missing or incompatible' >&2; exit 1; }
case "${1-}" in
    diagnose|resolve-cleanup)
        echo "niri-input recovery requires the Rust service binary" >&2
        exit 1
        ;;
esac
exec python3 -u "$directory/niri_tools.py" "$@"

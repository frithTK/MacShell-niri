#!/bin/sh
set -eu
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$directory/biometric-probe-rust"
if [ -x "$binary" ] && [ "$(timeout 3 "$binary" --protocol-version 2>/dev/null || :)" = "macshell-biometric-probe 1" ]; then
    exec "$binary" "$@"
fi
if [ -e "$directory/.macshell-rust-only" ] || [ -L "$directory/.macshell-rust-only" ]; then
    echo 'Biometric Rust service is missing or incompatible' >&2
    exit 1
fi
exec python3 -u "$directory/biometric_probe.py" "$@"

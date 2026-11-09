#!/bin/sh
set -eu
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$directory/fingerprint-operation-rust"
if [ -x "$binary" ] && [ "$(timeout 3 "$binary" --protocol-version 2>/dev/null || :)" = "macshell-fingerprint-operation 1" ]; then
    exec "$binary" "$@"
fi
if [ -e "$directory/.macshell-rust-only" ] || [ -L "$directory/.macshell-rust-only" ]; then
    echo 'Fingerprint Rust service is missing or incompatible' >&2
    exit 1
fi
exec python3 -u "$directory/fingerprint_operation.py" "$@"

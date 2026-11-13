#!/bin/sh
set -eu
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$directory/fingerprint-operation-rust"
if [ -x "$binary" ] && [ "$(timeout 3 "$binary" --unlock-protocol-version 2>/dev/null || :)" = "macshell-fingerprint-unlock 1" ]; then
    exec "$binary" unlock
fi
echo 'Fingerprint unlock Rust helper is missing or incompatible' >&2
exit 1

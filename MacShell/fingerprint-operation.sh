#!/bin/sh
set -eu
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$directory/fingerprint-operation-rust"
if [ -x "$binary" ] && [ "$(timeout 3 "$binary" --protocol-version 2>/dev/null || :)" = "macshell-fingerprint-operation 1" ]; then
    exec "$binary" "$@"
fi
echo 'Fingerprint Rust service is missing or incompatible' >&2
exit 1

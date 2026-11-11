#!/bin/sh
set -eu
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$directory/biometric-probe-rust"
if [ -x "$binary" ] && [ "$(timeout 3 "$binary" --protocol-version 2>/dev/null || :)" = "macshell-biometric-probe 1" ]; then
    exec "$binary" "$@"
fi
echo 'Biometric Rust service is missing or incompatible' >&2
exit 1

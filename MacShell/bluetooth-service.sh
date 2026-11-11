#!/bin/sh
set -eu
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$directory/bluetooth-service-rust"
if [ -x "$binary" ] && [ "$(timeout 3 "$binary" --protocol-version 2>/dev/null || :)" = "macshell-bluetooth 1" ]; then
    exec "$binary" "$@"
fi
echo 'Bluetooth Rust service is missing or incompatible' >&2
exit 1

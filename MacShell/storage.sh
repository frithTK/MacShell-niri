#!/bin/sh
set -eu
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$directory/storage-rust"
if [ -x "$binary" ] && [ "$(timeout 3 "$binary" --protocol-version 2>/dev/null || true)" = "macshell-storage 1" ]; then
    exec "$binary" "$@"
fi
echo 'storage helper is missing or incompatible' >&2
exit 1

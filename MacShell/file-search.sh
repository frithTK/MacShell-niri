#!/bin/sh
set -eu
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$directory/file-search-rust"
if [ -x "$binary" ] && [ "$(timeout 3 "$binary" --protocol-version 2>/dev/null || true)" = "macshell-file-search 1" ]; then
    exec "$binary" "$@"
fi
echo 'file-search helper is missing or incompatible' >&2
exit 1

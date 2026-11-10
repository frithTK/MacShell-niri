#!/bin/sh
set -eu
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$directory/desktop-source-rust"
if [ -x "$binary" ] && [ "$(timeout 3 "$binary" --protocol-version 2>/dev/null || true)" = "macshell-desktop-source 1" ]; then
    exec "$binary" "$@"
fi
echo 'desktop-source helper is missing or incompatible' >&2
exit 1

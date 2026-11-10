#!/bin/sh
set -eu
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$directory/app-menu-rust"
if [ -x "$binary" ] && [ "$(timeout 3 "$binary" --protocol-version 2>/dev/null || true)" = "macshell-app-menu 1" ]; then
    exec "$binary" "$@"
fi
echo 'app menu helper is missing or incompatible' >&2
exit 1

#!/bin/sh
set -eu
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$directory/widget-preferences-rust"
if [ -x "$binary" ] && [ "$(timeout 3 "$binary" --protocol-version 2>/dev/null || :)" = "macshell-widget-preferences 1" ]; then
    exec "$binary" "$@"
fi
echo 'Widget preferences Rust service is missing or incompatible' >&2
exit 1

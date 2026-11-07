#!/bin/sh
set -eu
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$directory/widget-preferences-rust"
if [ -x "$binary" ] && [ "$(timeout 3 "$binary" --protocol-version 2>/dev/null || :)" = "macshell-widget-preferences 1" ]; then
    exec "$binary" "$@"
fi
exec python3 -u "$directory/widget_layout_service.py" "$@"

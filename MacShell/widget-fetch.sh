#!/bin/sh
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$directory/widget-fetch-rust"
if [ -x "$binary" ] && [ "$("$binary" --protocol-version 2>/dev/null)" = "macshell-widget-fetch 1" ]; then
    exec "$binary" "$@"
fi
exec python3 -u "$directory/widget_fetch.py" "$@"

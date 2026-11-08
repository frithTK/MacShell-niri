#!/bin/sh
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$directory/wallpaper-discovery-rust"
if [ -x "$binary" ] && [ "$("$binary" --protocol-version 2>/dev/null)" = "macshell-wallpaper-discovery 1" ]; then
    exec "$binary" "$@"
fi
exec python3 -u "$directory/niri_wallpaper.py" "$@"

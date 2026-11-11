#!/bin/sh
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$directory/wallpaper-discovery-rust"
if [ -x "$binary" ] && [ "$("$binary" --protocol-version 2>/dev/null)" = "macshell-wallpaper-discovery 1" ]; then
    exec "$binary" "$@"
fi
echo 'Wallpaper Rust service is missing or incompatible' >&2
exit 1

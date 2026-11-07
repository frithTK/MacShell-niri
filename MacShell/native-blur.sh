#!/bin/sh
set -eu
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$directory/native-blur-rust"
if [ -x "$binary" ] && [ "$(timeout 3 "$binary" --protocol-version 2>/dev/null || :)" = "macshell-native-blur 1" ]; then
    exec "$binary" "$@"
fi
exec python3 -u "$directory/native_blur.py" "$@"

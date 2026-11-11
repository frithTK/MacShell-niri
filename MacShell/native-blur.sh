#!/bin/sh
set -eu
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$directory/native-blur-rust"
if [ -x "$binary" ] && [ "$(timeout 3 "$binary" --protocol-version 2>/dev/null || :)" = "macshell-native-blur 1" ]; then
    exec "$binary" "$@"
fi
echo 'Blur Rust service is missing or incompatible' >&2
exit 1

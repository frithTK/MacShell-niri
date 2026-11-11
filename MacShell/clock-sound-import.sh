#!/bin/sh
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$directory/clock-sound-import-rust"
if [ -x "$binary" ] && [ "$("$binary" --protocol-version 2>/dev/null)" = "macshell-clock-import 1" ]; then
    exec "$binary" "$@"
fi
echo 'Clock importer Rust service is missing or incompatible' >&2
exit 1

#!/bin/sh
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$directory/screen-mirroring-service-rust"
if [ -x "$binary" ] && [ "$("$binary" --protocol-version 2>/dev/null)" = "macshell-screen-mirroring 1" ]; then
    exec "$binary" "$@"
fi
echo 'Screen Mirroring Rust service is missing or incompatible' >&2
exit 1

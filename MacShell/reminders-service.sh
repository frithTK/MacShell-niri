#!/bin/sh
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$directory/reminders-service-rust"
if [ -x "$binary" ] && [ "$("$binary" --protocol-version 2>/dev/null)" = "macshell-reminders-service 1" ]; then
    exec "$binary" "$@"
fi
echo 'Reminders Rust service is missing or incompatible' >&2
exit 1

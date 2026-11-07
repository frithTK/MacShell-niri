#!/bin/sh
set -eu
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$directory/activity-preferences-rust"
if [ -x "$binary" ] && [ "$(timeout 3 "$binary" --protocol-version 2>/dev/null || :)" = "macshell-activity-preferences 1" ]; then
    exec "$binary" "$@"
fi
exec python3 -u "$directory/activity_preferences_service.py" "$@"

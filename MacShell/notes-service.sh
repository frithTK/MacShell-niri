#!/bin/sh
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$directory/notes-service-rust"
if [ -x "$binary" ] && [ "$("$binary" --protocol-version 2>/dev/null)" = "macshell-notes-service 1" ]; then
    exec "$binary" "$@"
fi
[ ! -e "$directory/.macshell-rust-only" ] && [ ! -L "$directory/.macshell-rust-only" ] || { echo 'Notes Rust service is missing or incompatible' >&2; exit 1; }
exec python3 -u "$directory/notes_service.py" "$@"

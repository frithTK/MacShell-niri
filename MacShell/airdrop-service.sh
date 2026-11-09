#!/bin/sh
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$directory/airdrop-service-rust"
if [ -x "$binary" ] && [ "$("$binary" --protocol-version 2>/dev/null)" = "macshell-airdrop-service 1" ]; then
    exec "$binary" "$@"
fi
if [ -e "$directory/.macshell-rust-only" ] || [ -L "$directory/.macshell-rust-only" ]; then
    echo 'AirDrop Rust service is missing or incompatible' >&2
    exit 1
fi
exec python3 -u "$directory/airdrop_service.py" "$@"

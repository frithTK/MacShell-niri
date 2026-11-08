#!/bin/sh
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$directory/currency-fetch-rust"
if [ -x "$binary" ] && [ "$("$binary" --protocol-version 2>/dev/null)" = "macshell-currency-fetch 1" ]; then
    exec "$binary" "$@"
fi
exec python3 -u "$directory/currency_fetch.py" "$@"

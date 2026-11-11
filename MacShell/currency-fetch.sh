#!/bin/sh
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$directory/currency-fetch-rust"
if [ -x "$binary" ] && [ "$("$binary" --protocol-version 2>/dev/null)" = "macshell-currency-fetch 1" ]; then
    exec "$binary" "$@"
fi
echo 'Currency Rust service is missing or incompatible' >&2
exit 1

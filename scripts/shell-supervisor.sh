#!/bin/sh
set -eu
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$directory/session-preflight-rust"
if [ -x "$binary" ] && [ "$(timeout 3 "$binary" --supervisor-protocol-version 2>/dev/null || :)" = "macshell-shell-supervisor 1" ]; then
    case "${1-}" in
        start) shift; exec "$binary" --supervisor-start "$@" ;;
        check) shift; exec "$binary" --supervisor-check "$@" ;;
    esac
fi
[ ! -e "$directory/.macshell-rust-only" ] && [ ! -L "$directory/.macshell-rust-only" ] || { echo 'Shell supervisor Rust helper is missing or incompatible' >&2; exit 1; }
exec python3 "$directory/shell-supervisor.py" "$@"

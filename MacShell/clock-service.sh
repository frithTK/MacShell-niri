#!/bin/sh
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$directory/clock-service-prototype-rust"
if [ -x "$binary" ] && [ -x "$directory/clock-audio-worker-rust" ] && [ "$("$binary" --protocol-version 2>/dev/null)" = "macshell-clock-service 1" ]; then
    store=
    audio=
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --store) store=$2; shift 2 ;;
            --audio-dir) audio=$2; shift 2 ;;
            *) exit 2 ;;
        esac
    done
    if [ -n "$audio" ]; then
        exec "$binary" --prototype --store "$store" --audio-dir "$audio" --builtin-dir "$directory/sounds" --audio-worker "$directory/clock-audio-worker-rust"
    fi
    exec "$binary" --prototype --store "$store"
fi
echo 'Clock Rust service or audio worker is missing or incompatible' >&2
exit 1

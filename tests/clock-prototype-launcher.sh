#!/bin/sh
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
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
    exec "$directory/clock-service-prototype" --prototype --store "$store" --audio-dir "$audio" --builtin-dir "$directory/sounds" --audio-worker "$directory/clock-audio-worker"
fi
exec "$directory/clock-service-prototype" --prototype --store "$store"

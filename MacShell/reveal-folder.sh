#!/bin/sh
# Open a path in a graphical file manager. Never fall back to xdg-open:
# inode/directory is often a terminal FM (ranger, yazi, lf) or the default
# handler for a file is a terminal editor.
set -eu

path=${1-}
uri=${2-}
mode=${3-open}

case $path in
    /*) ;;
    *) exit 2 ;;
esac
case $path in
    *[$'\n\r']*) exit 2 ;;
esac

if [ ! -e "$path" ]; then
    exit 3
fi

if [ "$mode" = "select" ]; then
    method=ShowItems
    if [ -d "$path" ]; then
        dir=$path
        file=
        method=ShowFolders
    else
        dir=$(dirname -- "$path")
        file=$path
    fi
else
    method=ShowFolders
    if [ -d "$path" ]; then
        dir=$path
        file=
    else
        dir=$(dirname -- "$path")
        file=
    fi
fi

if command -v gdbus >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1 && [ -n "$uri" ]; then
    if timeout 2 gdbus call --session \
        --dest org.freedesktop.FileManager1 \
        --object-path /org/freedesktop/FileManager1 \
        --method org.freedesktop.FileManager1."$method" \
        "['$uri']" "" >/dev/null 2>&1; then
        exit 0
    fi
fi

open_gui() {
    if [ -n "$file" ]; then
        if command -v dolphin >/dev/null 2>&1; then
            exec dolphin --select -- "$file"
        fi
        if command -v nautilus >/dev/null 2>&1; then
            exec nautilus --select -- "$file"
        fi
        if command -v nemo >/dev/null 2>&1; then
            exec nemo --no-desktop -- "$dir"
        fi
        if command -v thunar >/dev/null 2>&1; then
            exec thunar -- "$dir"
        fi
        if command -v pcmanfm-qt >/dev/null 2>&1; then
            exec pcmanfm-qt -- "$dir"
        fi
        if command -v pcmanfm >/dev/null 2>&1; then
            exec pcmanfm -- "$dir"
        fi
        if command -v caja >/dev/null 2>&1; then
            exec caja -- "$dir"
        fi
    fi
    if command -v dolphin >/dev/null 2>&1; then
        exec dolphin -- "$dir"
    fi
    if command -v nautilus >/dev/null 2>&1; then
        exec nautilus -- "$dir"
    fi
    if command -v nemo >/dev/null 2>&1; then
        exec nemo --no-desktop -- "$dir"
    fi
    if command -v thunar >/dev/null 2>&1; then
        exec thunar -- "$dir"
    fi
    if command -v pcmanfm-qt >/dev/null 2>&1; then
        exec pcmanfm-qt -- "$dir"
    fi
    if command -v pcmanfm >/dev/null 2>&1; then
        exec pcmanfm -- "$dir"
    fi
    if command -v caja >/dev/null 2>&1; then
        exec caja -- "$dir"
    fi
    if command -v notify-send >/dev/null 2>&1; then
        notify-send -a MacShell "Storage" "No graphical file manager found"
    fi
    exit 4
}

open_gui

#!/usr/bin/env bash
set -euo pipefail
settings_dir="${MACSHELL_SETTINGS_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}}/macshell"
runtime_dir="${XDG_RUNTIME_DIR:-/tmp}/macshell-niri-wallpaper-$UID"
mkdir -p "$settings_dir" "$runtime_dir"
chmod 700 "$runtime_dir"
prepare=0
if [[ ${1:-} == --prepare ]]; then prepare=1; shift; fi
wallpaper_file="${1:?Wallpaper path required}"
[[ -f "$wallpaper_file" ]] || { echo "Wallpaper does not exist" >&2; exit 1; }
if [[ "$prepare" == 0 && -f "$runtime_dir/pid" ]]; then
    read -r wallpaper_pid < "$runtime_dir/pid"
    if [[ "$wallpaper_pid" =~ ^[0-9]+$ && -r "/proc/$wallpaper_pid/comm" && $(cat "/proc/$wallpaper_pid/comm") == mpvpaper ]]; then
        kill "$wallpaper_pid" 2>/dev/null || true
    fi
    rm -f "$runtime_dir/pid"
fi
case "${wallpaper_file,,}" in
    *.mp4|*.webm|*.mkv|*.mov|*.m4v)
        thumb_dir="${XDG_CACHE_HOME:-$HOME/.cache}/macshell-niri/wallpapers"
        mkdir -p "$thumb_dir"
        thumb_key=$(printf '%s' "$wallpaper_file" | sha256sum | cut -d' ' -f1)
        thumb_file="$thumb_dir/$thumb_key.jpg"
        if [[ ! -s "$thumb_file" ]]; then
            ffmpeg -nostdin -loglevel error -y -i "$wallpaper_file" -frames:v 1 -vf 'scale=1920:-2' "$thumb_file"
        fi
        if [[ "$prepare" == 0 ]]; then
            command -v mpvpaper >/dev/null || { echo 'Install mpvpaper for animated wallpapers' >&2; exit 1; }
            mpvpaper -o 'no-audio loop hwdec=auto' '*' "$wallpaper_file" >/dev/null 2>&1 &
            printf '%s\n' "$!" > "$runtime_dir/pid"
            printf '%s\n' "$wallpaper_file" > "$settings_dir/wallpaper-video"
        fi
        printf '%s\n' "$thumb_file"
        ;;
    *)
        rm -f "$settings_dir/wallpaper-video"
        printf '%s\n' "$wallpaper_file"
        ;;
esac

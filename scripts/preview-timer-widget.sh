#!/usr/bin/env bash
# Capture the demo timer widgets in either supported interface language.
set -euo pipefail
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$source_dir"
preview_language=${1:-en}
output_dir=${2:-"$source_dir/docs/images"}
if [[ "$preview_language" != en && "$preview_language" != ru ]]; then
    printf 'Usage: %s [en|ru] [output-directory]\n' "$0" >&2
    exit 2
fi
mkdir -p "$output_dir"
output_dir=$(cd "$output_dir" && pwd)
qs_binary=$(python3 -c 'from scripts.install_niri import quickshell; print(quickshell())')
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
mkdir -p "$check_dir/runtime" "$check_dir/cache" "$check_dir/config"
chmod 700 "$check_dir/runtime"
cp -R MacShell "$check_dir/preview"
cp tests/timer-widget-preview.qml "$check_dir/preview/shell.qml"
preview_russian=0
[[ "$preview_language" != ru ]] || preview_russian=1
for theme in dark light; do
    preview_light=0
    [[ "$theme" != light ]] || preview_light=1
    env -u DISPLAY -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME= \
        QT_QUICK_BACKEND=software QT_QUICK_CONTROLS_STYLE=Basic \
        XDG_RUNTIME_DIR="$check_dir/runtime" XDG_CACHE_HOME="$check_dir/cache" XDG_CONFIG_HOME="$check_dir/config" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$check_dir/no-bus" \
        MACSHELL_PREVIEW_RUSSIAN="$preview_russian" MACSHELL_PREVIEW_LIGHT="$preview_light" \
        MACSHELL_PREVIEW_CAPTURE="$output_dir/timer-widget-$preview_language-$theme.png" \
        timeout 12 "$qs_binary" -p "$check_dir/preview"
done

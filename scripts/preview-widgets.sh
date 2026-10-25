#!/usr/bin/env bash
set -euo pipefail
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$source_dir"
qs_binary=$(python3 -c 'from scripts.install_niri import quickshell; print(quickshell())')
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
mkdir -p "$check_dir/runtime" "$check_dir/cache" "$check_dir/config"
chmod 700 "$check_dir/runtime"
cp -R MacShell "$check_dir/preview"
sed 's|import "../MacShell" as Port|import "." as Port|' tests/widget-gallery-preview.qml > "$check_dir/preview/shell.qml"
for variant in normal recovery editor displays add appearance; do
for theme in dark light; do
    preview_light=0
    [[ "$theme" != light ]] || preview_light=1
    preview_recovery=0
    preview_editor=0
    preview_displays=0
    preview_add=0
    preview_appearance=0
    preview_name="widgets-$theme.png"
    if [[ "$variant" == recovery ]]; then
        preview_recovery=1
        preview_name="widgets-recovery-$theme.png"
    fi
    if [[ "$variant" == editor ]]; then
        preview_editor=1
        preview_name="widgets-editor-$theme.png"
    fi
    if [[ "$variant" == displays ]]; then
        preview_displays=1
        preview_name="widgets-displays-$theme.png"
    fi
    if [[ "$variant" == add ]]; then
        preview_add=1
        preview_name="widgets-add-$theme.png"
    fi
    if [[ "$variant" == appearance ]]; then
        preview_appearance=1
        preview_name="widgets-appearance-$theme.png"
    fi
    env -u DISPLAY -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME= \
        QT_QUICK_BACKEND=software QT_QUICK_CONTROLS_STYLE=Basic \
        XDG_RUNTIME_DIR="$check_dir/runtime" XDG_CACHE_HOME="$check_dir/cache" XDG_CONFIG_HOME="$check_dir/config" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$check_dir/no-bus" MACSHELL_SETTINGS_HOME="$check_dir/settings" \
        MACSHELL_PREVIEW_LIGHT="$preview_light" MACSHELL_PREVIEW_RECOVERY="$preview_recovery" MACSHELL_PREVIEW_EDITOR="$preview_editor" MACSHELL_PREVIEW_DISPLAYS="$preview_displays" MACSHELL_PREVIEW_ADD="$preview_add" MACSHELL_PREVIEW_APPEARANCE="$preview_appearance" MACSHELL_PREVIEW_CAPTURE="$source_dir/docs/images/$preview_name" \
        timeout 12 "$qs_binary" -p "$check_dir/preview"
done
done

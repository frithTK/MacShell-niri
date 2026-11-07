#!/usr/bin/env bash
set -euo pipefail
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$source_dir"
qs_binary=$(python3 -c 'from scripts.install_niri import quickshell; print(quickshell())')
bash scripts/check-portable.sh
niri validate -c config/macshell.kdl
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
chmod 700 "$check_dir"
qml_compiler=/usr/lib/qt6/qmlcachegen
[[ -x "$qml_compiler" ]] || qml_compiler=$(command -v qmlcachegen6)
while IFS= read -r qml_file; do
    "$qml_compiler" -o "$check_dir/$(basename "$(dirname "$qml_file")")-$(basename "$qml_file").qmlc" "$qml_file"
done < <(rg --files MacShell MacLock -g '*.qml')
shader_compiler=$(command -v qsb || true)
shader_compiler=${shader_compiler:-/usr/lib/qt6/bin/qsb}
for shader_file in MacShell/*.frag MacLock/*.frag; do
    "$shader_compiler" --qt6 -o "$check_dir/$(basename "$(dirname "$shader_file")")-$(basename "$shader_file").qsb" "$shader_file" > /dev/null
done
mkdir -p "$check_dir/config" "$check_dir/cache" "$check_dir/runtime"
chmod 700 "$check_dir/runtime"
bash scripts/check-qml.sh
mkdir -p "$check_dir/bluetooth"
cp MacShell/BluetoothControl.qml MacShell/JsonService.qml MacShell/bluetooth-service.sh "$check_dir/bluetooth/"
cp -R MacShell/Locale "$check_dir/bluetooth/Locale"
cp tests/fixtures/bluetooth_service.py "$check_dir/bluetooth/bluetooth_service.py"
cp tests/bluetooth.qml "$check_dir/bluetooth/shell.qml"
if ! env -u DISPLAY -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME= \
    XDG_CONFIG_HOME="$check_dir/config" XDG_CACHE_HOME="$check_dir/cache" XDG_RUNTIME_DIR="$check_dir/runtime" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=$check_dir/no-bus" \
    timeout 10 "$qs_binary" -p "$check_dir/bluetooth" > "$check_dir/bluetooth.log" 2>&1; then cat "$check_dir/bluetooth.log"; exit 1; fi
if ! rg -q MACSHELL_BLUETOOTH_PASS "$check_dir/bluetooth.log"; then cat "$check_dir/bluetooth.log"; exit 1; fi
cp -R MacShell "$check_dir/adapter"
sed 's|import "../MacShell" as Port|import "." as Port|' tests/adapter.qml > "$check_dir/adapter/shell.qml"
if ! env -u DISPLAY -u WAYLAND_DISPLAY MACSHELL_SETTINGS_HOME="$check_dir/settings" XDG_CONFIG_HOME="$check_dir/config" XDG_CACHE_HOME="$check_dir/cache" XDG_RUNTIME_DIR="$check_dir/runtime" NIRI_SOCKET="$check_dir/no-session" QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME= QT_QUICK_CONTROLS_STYLE=Basic DBUS_SESSION_BUS_ADDRESS="unix:path=$check_dir/no-bus" \
    timeout 10 "$qs_binary" -p "$check_dir/adapter" > "$check_dir/adapter.log" 2>&1; then cat "$check_dir/adapter.log"; exit 1; fi
if ! rg -q MACSHELL_ADAPTER_PASS "$check_dir/adapter.log"; then cat "$check_dir/adapter.log"; exit 1; fi
python3 scripts/check-preview-reload.py
dbus-run-session -- python3 tests/fixtures/fingerprint_dbus.py
sed 's|import "." as Port|import "." as Port|' tests/services.qml > "$check_dir/adapter/shell.qml"
if ! env -u DISPLAY -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME= QT_QUICK_CONTROLS_STYLE=Basic \
    XDG_CONFIG_HOME="$check_dir/config" XDG_CACHE_HOME="$check_dir/cache" XDG_RUNTIME_DIR="$check_dir/runtime" \
    DBUS_SYSTEM_BUS_ADDRESS="unix:path=$check_dir/no-bus" DBUS_SESSION_BUS_ADDRESS="unix:path=$check_dir/no-bus" \
    timeout 10 "$qs_binary" -p "$check_dir/adapter" > "$check_dir/services.log" 2>&1; then cat "$check_dir/services.log"; exit 1; fi
if ! rg -q MACSHELL_SERVICES_PASS "$check_dir/services.log"; then cat "$check_dir/services.log"; exit 1; fi
sed 's|import "../MacShell" as Port|import "." as Port|' tests/glass-regions.qml > "$check_dir/adapter/shell.qml"
if ! env -u DISPLAY -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME= QT_QUICK_CONTROLS_STYLE=Basic \
    XDG_CONFIG_HOME="$check_dir/config" XDG_CACHE_HOME="$check_dir/cache" XDG_RUNTIME_DIR="$check_dir/runtime" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=$check_dir/no-bus" \
    timeout 10 "$qs_binary" -p "$check_dir/adapter" > "$check_dir/glass-regions.log" 2>&1; then cat "$check_dir/glass-regions.log"; exit 1; fi
if ! rg -q MACSHELL_GLASS_REGIONS_PASS "$check_dir/glass-regions.log"; then cat "$check_dir/glass-regions.log"; exit 1; fi
cp tests/activity-preferences.qml "$check_dir/adapter/shell.qml"
if ! env -u DISPLAY -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME= QT_QUICK_CONTROLS_STYLE=Basic \
    XDG_CONFIG_HOME="$check_dir/config" XDG_CACHE_HOME="$check_dir/cache" XDG_RUNTIME_DIR="$check_dir/runtime" \
    MACSHELL_SETTINGS_HOME="$check_dir/activity-settings" DBUS_SESSION_BUS_ADDRESS="unix:path=$check_dir/no-bus" \
    timeout 10 "$qs_binary" -p "$check_dir/adapter" > "$check_dir/activity-preferences.log" 2>&1; then cat "$check_dir/activity-preferences.log"; exit 1; fi
if ! rg -q MACSHELL_ACTIVITY_PREFERENCES_PASS "$check_dir/activity-preferences.log"; then cat "$check_dir/activity-preferences.log"; exit 1; fi
cp tests/bar-preferences.qml "$check_dir/adapter/shell.qml"
if ! env -u DISPLAY -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME= QT_QUICK_CONTROLS_STYLE=Basic \
    XDG_CONFIG_HOME="$check_dir/config" XDG_CACHE_HOME="$check_dir/cache" XDG_RUNTIME_DIR="$check_dir/runtime" \
    MACSHELL_SETTINGS_HOME="$check_dir/bar-settings" DBUS_SESSION_BUS_ADDRESS="unix:path=$check_dir/no-bus" \
    timeout 10 "$qs_binary" -p "$check_dir/adapter" > "$check_dir/bar-preferences.log" 2>&1; then cat "$check_dir/bar-preferences.log"; exit 1; fi
if ! rg -q MACSHELL_BAR_PREFERENCES_PASS "$check_dir/bar-preferences.log"; then cat "$check_dir/bar-preferences.log"; exit 1; fi
cp tests/widget-preferences.qml "$check_dir/adapter/shell.qml"
if ! env -u DISPLAY -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME= QT_QUICK_CONTROLS_STYLE=Basic \
    XDG_CONFIG_HOME="$check_dir/config" XDG_CACHE_HOME="$check_dir/cache" XDG_RUNTIME_DIR="$check_dir/runtime" \
    MACSHELL_SETTINGS_HOME="$check_dir/widget-settings" DBUS_SESSION_BUS_ADDRESS="unix:path=$check_dir/no-bus" \
    timeout 10 "$qs_binary" -p "$check_dir/adapter" > "$check_dir/widget-preferences.log" 2>&1; then cat "$check_dir/widget-preferences.log"; exit 1; fi
if ! rg -q MACSHELL_WIDGET_PREFERENCES_PASS "$check_dir/widget-preferences.log"; then cat "$check_dir/widget-preferences.log"; exit 1; fi
python3 scripts/check-widget-outputs.py
python3 scripts/check-widget-lifecycle.py
python3 scripts/check-maclock-language.py
python3 scripts/check-maclock-clock.py
printf '%s\n' 'Control services, private D-Bus protocols, QML interactions/migrations, Activity transactions, shaders, IPC, capture buffers and installer rollback checks passed.'

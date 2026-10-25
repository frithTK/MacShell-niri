#!/usr/bin/env bash
set -euo pipefail
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$source_dir"

qml_test_runner=${MACSHELL_QML_TEST_RUNNER:-}
if [[ -z "$qml_test_runner" && -n "${QT_ROOT_DIR:-}" && -x "$QT_ROOT_DIR/bin/qmltestrunner" ]]; then
    qml_test_runner="$QT_ROOT_DIR/bin/qmltestrunner"
fi
if [[ -z "$qml_test_runner" ]]; then
    # An unversioned system runner can belong to Qt 5.
    for candidate in qmltestrunner6 /usr/lib/qt6/bin/qmltestrunner /usr/lib/qt6/qmltestrunner qmltestrunner; do
        if command -v "$candidate" > /dev/null 2>&1; then
            qml_test_runner=$(command -v "$candidate")
            break
        fi
    done
fi
if [[ -z "$qml_test_runner" ]]; then
    printf '%s\n' 'Qt 6 qmltestrunner not found. Install Qt Quick Test or set MACSHELL_QML_TEST_RUNNER.' >&2
    exit 1
fi

check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
mkdir -p "$check_dir/runtime" "$check_dir/cache" "$check_dir/config"
chmod 700 "$check_dir/runtime"
env -u DISPLAY -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME= \
    QT_QUICK_BACKEND=software QT_QUICK_CONTROLS_STYLE=Basic \
    XDG_RUNTIME_DIR="$check_dir/runtime" XDG_CACHE_HOME="$check_dir/cache" XDG_CONFIG_HOME="$check_dir/config" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=$check_dir/no-bus" \
    "$qml_test_runner" -input tests/qml -o -,txt

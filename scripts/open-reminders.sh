#!/usr/bin/env bash
set -euo pipefail
project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
config_path="$project_dir/MacShell/reminders-standalone.qml"
data_dir=${XDG_DATA_HOME:-"$HOME/.local/share"}
qs_binary=${MACSHELL_QS_BIN:-"$data_dir/macshell-niri/runtime/bin/qs"}
if [[ ! -x "$qs_binary" ]]; then qs_binary=$(command -v qs); fi
if "$qs_binary" -p "$config_path" ipc call remindersPreview open >/dev/null 2>&1; then exit 0; fi
exec "$qs_binary" -d -p "$config_path"

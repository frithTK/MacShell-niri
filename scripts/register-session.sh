#!/usr/bin/env bash
# Register only the two MacShell session files; never restart the display manager.
set -euo pipefail
bundle_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
entry_file=/usr/local/share/wayland-sessions/niri-macshell.desktop
launcher_file=/usr/local/bin/niri-macshell-session
if [[ $EUID != 0 ]]; then
    echo "Run: sudo bash $bundle_dir/register-session.sh" >&2
    exit 1
fi
check_owned() {
    local destination=$1 marker=$2
    if [[ -e "$destination" ]] && ! grep -Fq "$marker" "$destination"; then
        echo "Refusing to replace an unrelated file: $destination" >&2
        exit 1
    fi
}
check_owned "$entry_file" 'Comment=MacShell profile;'
check_owned "$launcher_file" 'MacShell SDDM entry dispatcher.'
if [[ ${1:-} == --remove ]]; then
    rm -f -- "$entry_file" "$launcher_file"
    echo 'Removed the MacShell login entry. The original Niri entry is unchanged.'
    exit 0
fi
[[ $# == 0 ]] || { echo 'Usage: register-session.sh [--remove]' >&2; exit 1; }
desktop-file-validate "$bundle_dir/niri-macshell.desktop"
install -D -m 0755 "$bundle_dir/session-entry.sh" "$launcher_file"
install -D -m 0644 "$bundle_dir/niri-macshell.desktop" "$entry_file"
echo 'Registered Niri (MacShell). Choose it at the next login; Niri still starts the original desktop.'

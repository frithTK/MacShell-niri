#!/usr/bin/env bash
# Separate SDDM session. The standard niri.service is left untouched.
set -euo pipefail
profile_config=@PROFILE_CONFIG@
preflight=@PREFLIGHT@
qs_binary=@QS_BINARY@
locale_helper=@LOCALE_HELPER@
if [[ ${1:-} == --check ]]; then
    exec "$preflight" "$profile_config" "$qs_binary"
fi
# Match niri-session's login environment (including fish users).
if [[ ${1:-} != --login-env && -n ${SHELL:-} ]] && grep -Fxq "$SHELL" /etc/shells; then
    exec "$SHELL" -l -c 'exec "$HOME/.local/bin/niri-macshell-session" --login-env'
fi
export XDG_CURRENT_DESKTOP=niri XDG_SESSION_DESKTOP=niri XDG_SESSION_TYPE=wayland
log_dir=${XDG_STATE_HOME:-$HOME/.local/state}/macshell-niri
mkdir -p -- "$log_dir"
exec >>"$log_dir/session.log" 2>&1
printf '\nMacShell login: %s\n' "$(date -Is)"
fallback() {
    echo "$1" >&2
    logger -t niri-macshell "$1" || true
    exec /usr/bin/niri-session
}
if systemctl --user --quiet is-active niri.service || systemctl --user --quiet is-active niri-macshell.service; then
    echo 'A niri session is already running. Select MacShell at the login screen after logging out.' >&2
    exit 1
fi
if ! "$preflight" "$profile_config" "$qs_binary"; then
    fallback 'Preflight failed; starting the original Niri session.'
fi
# Apply the user's locale before compositor/app startup and environment import.
# The helper emits whitelisted assignments, never shell source. On invalid input
# retain the login environment and report the problem rather than deny login.
if locale_values=$("$locale_helper"); then
    while IFS='=' read -r locale_key locale_value; do
        case "$locale_key" in
            LANG|LANGUAGE|LC_MESSAGES|LC_NUMERIC|LC_TIME|LC_MONETARY|LC_PAPER|LC_NAME|LC_ADDRESS|LC_TELEPHONE|LC_MEASUREMENT|LC_IDENTIFICATION)
                export "$locale_key=$locale_value" ;;
            '') ;;
            *) echo 'Rejected unexpected locale variable.' >&2; exit 1 ;;
        esac
    done <<< "$locale_values"
fi
if ! systemctl --user daemon-reload; then
    fallback 'Cannot reload MacShell service; starting the original Niri session.'
fi
# reset-failed only operates on units already loaded by the user manager.
# A new login may have no loaded MacShell unit until start loads it below.
systemctl --user reset-failed niri-macshell.service 2>/dev/null || true
# A new login gets a new token; restarting Quickshell within this login keeps it.
IFS= read -r MACSHELL_SESSION_TOKEN < /proc/sys/kernel/random/uuid
export MACSHELL_SESSION_TOKEN
export MACSHELL_MANAGED_SHELL=1
if ! systemctl --user import-environment; then
    fallback 'Cannot import login environment; starting the original Niri session.'
fi
if command -v dbus-update-activation-environment >/dev/null; then
    if ! dbus-update-activation-environment --all; then
        fallback 'Cannot import D-Bus environment; starting the original Niri session.'
    fi
fi
cleanup() {
    systemctl --user start --job-mode=replace-irreversibly niri-shutdown.target || true
    systemctl --user unset-environment WAYLAND_DISPLAY DISPLAY XDG_SESSION_TYPE XDG_CURRENT_DESKTOP NIRI_SOCKET MACSHELL_SESSION_TOKEN MACSHELL_MANAGED_SHELL || true
}
trap cleanup EXIT
if systemctl --user --wait start niri-macshell.service; then
    exit 0
fi
cleanup
trap - EXIT
fallback 'MacShell session failed; cleaned up and starting the original Niri session.'

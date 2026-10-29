#!/bin/sh
# Each WlSessionLock instance is used once. Start a fresh IPC-capable instance per lock.
set -u

if [ -z "${XDG_RUNTIME_DIR:-}" ] || [ ! -d "$XDG_RUNTIME_DIR" ]; then
    printf '%s\n' 'MacLock needs the user runtime directory.' >&2
    exit 1
fi
qs_binary=${MACSHELL_QS_BIN:-$(command -v qs)}
if [ -z "$qs_binary" ] || ! command -v systemd-run >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
    printf '%s\n' 'MacLock needs Quickshell, systemd-run and flock.' >&2
    exit 1
fi
# Serialize concurrent lock requests before checking IPC or creating a unit.
exec 9>"$XDG_RUNTIME_DIR/macshell-niri-lock.guard"
flock -x 9 || exit 1

get_state() {
    "$qs_binary" -c MacLock-niri ipc call lockscreen state 2>/dev/null || true
}

lock_now() {
    exec "$qs_binary" -c MacLock-niri ipc call lockscreen lock
}

state=$(get_state)
case "$state" in
    ready)
        lock_now
        ;;
    busy)
        # Already locked or currently entering the lock; don't start a competing locker.
        exit 0
        ;;
    stopping)
        # Unlock animation completed, but the prior WlSessionLock process is still exiting.
        tries=0
        while [ "$state" = "stopping" ] && [ "$tries" -lt 60 ]; do
            sleep 0.1
            state=$(get_state)
            tries=$((tries + 1))
        done
        if [ "$state" = "stopping" ]; then
            printf '%s\n' 'MacLock is still shutting down; try the lock key again in a moment.' >&2
            exit 1
        fi
        ;;
esac

# The locker must not be a child in the shell service's cgroup: stopping or
# restarting the shell must leave a live Wayland session lock untouched.
set -- systemd-run --user --unit=macshell-niri-lock --collect --service-type=exec \
    --slice=session.slice '--property=PartOf=niri-macshell.service graphical-session.target' \
    --setenv=MACLOCK_DAEMON=1 "--setenv=PATH=$PATH"
[ -z "${WAYLAND_DISPLAY:-}" ] || set -- "$@" "--setenv=WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
[ -z "${NIRI_SOCKET:-}" ] || set -- "$@" "--setenv=NIRI_SOCKET=$NIRI_SOCKET"
[ -z "${XDG_CONFIG_HOME:-}" ] || set -- "$@" "--setenv=XDG_CONFIG_HOME=$XDG_CONFIG_HOME"
[ -z "${XDG_CACHE_HOME:-}" ] || set -- "$@" "--setenv=XDG_CACHE_HOME=$XDG_CACHE_HOME"
[ -z "${MACSHELL_SETTINGS_HOME:-}" ] || set -- "$@" "--setenv=MACSHELL_SETTINGS_HOME=$MACSHELL_SETTINGS_HOME"
[ -z "${MACSHELL_SESSION_TOKEN:-}" ] || set -- "$@" "--setenv=MACSHELL_SESSION_TOKEN=$MACSHELL_SESSION_TOKEN"
[ -z "${MACLOCK_PAM_SERVICE:-}" ] || set -- "$@" "--setenv=MACLOCK_PAM_SERVICE=$MACLOCK_PAM_SERVICE"
[ -z "${MACLOCK_CLOCK:-}" ] || set -- "$@" "--setenv=MACLOCK_CLOCK=$MACLOCK_CLOCK"
[ -z "${MACLOCK_NP:-}" ] || set -- "$@" "--setenv=MACLOCK_NP=$MACLOCK_NP"
[ -z "${MACLOCK_ART:-}" ] || set -- "$@" "--setenv=MACLOCK_ART=$MACLOCK_ART"
[ -z "${QT_QUICK_CONTROLS_STYLE:-}" ] || set -- "$@" "--setenv=QT_QUICK_CONTROLS_STYLE=$QT_QUICK_CONTROLS_STYLE"
if ! "$@" "$qs_binary" -c MacLock-niri >/dev/null 2>&1; then
    printf '%s\n' 'Could not start the independent MacLock service.' >&2
    exit 1
fi
tries=0
while [ "$tries" -lt 60 ]; do
    state=$(get_state)
    case "$state" in
        ready) lock_now ;;
        busy) exit 0 ;;
    esac
    sleep 0.1
    tries=$((tries + 1))
done

printf '%s\n' 'MacLock IPC did not become ready. Check that Quickshell can load the MacLock config.' >&2
exit 1

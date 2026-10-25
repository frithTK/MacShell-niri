#!/bin/sh
# MacShell SDDM entry dispatcher. Executed as the logged-in desktop user.
set -eu
exec "$HOME/.local/bin/niri-macshell-session" "$@"

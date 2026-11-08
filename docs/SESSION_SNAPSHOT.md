# Session snapshot MVP

The session-preservation slice records the current Niri layout and can restore
workspace and floating/tiling placement for uniquely matched open windows.

## Commands

From the running MacShell session. These are requests to one persistent Rust
JSON-lines service; they do not start a Python process per command:

```sh
qs -c MacShell-niri ipc call session save
qs -c MacShell-niri ipc call session status
qs -c MacShell-niri ipc call session inspect
qs -c MacShell-niri ipc call session restorePlan
qs -c MacShell-niri ipc call session restore
qs -c MacShell-niri ipc call session state
qs -c MacShell-niri ipc call session result
```

Requests are asynchronous: a positive number is a request ID, `-1` means the
service is not ready and `-2` means another request is in progress. Wait until
`state` reports `busy: false`, then read `result` for the last completed
response, including its ID, action, success, result or error. The previous result
remains available while a new request is running. Snapshot data can contain
window titles and other session details.

The snapshot is stored at:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/macshell-niri/sessions/current.json
```

The installed backend is the Rust `macshell-session-service`, kept alive by
MacShell as a JSON-lines service. It uses a private lock, a temporary file,
`fsync`, and an atomic rename. The schema is versioned and corrupted/unknown
snapshots are rejected.

The snapshot contains Niri outputs, workspaces, filtered user windows, layout
metadata, and the currently focused window. Niri window IDs, PIDs, and workspace
IDs are intentionally not persisted as stable identities. The current
`persistent_key` is diagnostic only; stronger application identities remain
future work.

MacShell and Noctalia/service windows are excluded. The manual restore plan only
matches an existing window when its app-id and title are unique in both the
snapshot and the current session. It only targets an existing workspace,
floating/tiling mode; it never launches or closes applications. Use
`restorePlan` first. After executing actions, restore rereads the current state
and verifies all originally matched windows; skipped windows are listed in the
plan and are not verified. Application tabs, commands, URLs, window sizes,
fullscreen state, focus and shell state are not restored.

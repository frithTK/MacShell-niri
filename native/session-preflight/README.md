# Session preflight

This helper validates the generated niri configuration and probes the selected
Quickshell binary before a separate MacShell session starts. The runtime probe
uses a private temporary directory, an offscreen Qt platform and an unavailable
session bus. It rejects a failed process, a Qt rebuild warning, a configuration
load failure, invalid output and a timeout. Child output is bounded; on timeout
the helper stops its own process group.

`session-preflight.sh` checks the Rust protocol version and can fall back to the
previous Python helper. The installer refreshes the separate login script and
its helper with `--session`. A plain installation does not rewrite an existing
login script. The Python installer still uses its existing runtime check.

```sh
cargo test --locked --offline --manifest-path native/session-preflight/Cargo.toml
cargo build --locked --offline --manifest-path native/session-preflight/Cargo.toml
MACSHELL_TEST_PREFLIGHT_BINARY="$PWD/native/session-preflight/target/debug/macshell-session-preflight" \
  python3 -m unittest discover -s tests -p test_session_preflight_rust.py
```

The integration suite uses temporary fixtures and, when available, runs actual
`niri validate` and Quickshell offscreen. It never starts a user session.

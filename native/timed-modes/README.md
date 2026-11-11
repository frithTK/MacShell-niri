# Timed focus and idle inhibition

This service maintains the JSON-lines contract for focus and keep-awake modes. Fixed durations use Linux `CLOCK_BOOTTIME`, including suspend; "until evening" uses 20:00 in the local time zone. Focus can be restored across reboots using its wall-clock deadline. Keep-awake restores only for the same boot and confirmed session.

The session comes from the managed session token, or from a successful niri `Version` request and the socket's filesystem identity. A replaced socket, full backlog, missing socket or failed response leaves the session unknown. Saved unknown fields remain intact. The service only publishes state; it does not itself inhibit sleep or edit settings.

The installer builds the service offline before replacing installed files. The launcher requires a compatible Rust binary. Python remains for comparison tests and development tools.

```sh
cargo test --offline --locked --manifest-path native/timed-modes/Cargo.toml
cargo build --release --offline --locked --manifest-path native/timed-modes/Cargo.toml --target-dir /tmp/macshell-timed-modes-build
MACSHELL_TEST_TIMED_MODES_BINARY=/tmp/macshell-timed-modes-build/release/macshell-timed-modes python3 -m unittest discover -s tests -p test_timed_modes_rust.py
```

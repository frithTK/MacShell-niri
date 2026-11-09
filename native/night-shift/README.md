# Night Shift process owner

This service owns one `wlsunset` process and reports `starting`, `on`, `off`, `unavailable` or `error` to the existing JSON-lines client. It reports `on` only after observing a Wayland gamma request and a one-second failure window. Changing temperature replaces the old process; disabling or exiting terminates only the owned child. Linux parent-death signalling stops the child if the service is killed abruptly.

The installer builds and checks this component offline before replacing installed files. The installed launcher requires a compatible Rust binary; historical unmarked profiles can still use their legacy fallback.

The test suite uses a fake `wlsunset` and never changes display gamma:

```sh
cargo test --offline --locked --manifest-path native/night-shift/Cargo.toml
cargo build --release --offline --locked --manifest-path native/night-shift/Cargo.toml --target-dir /tmp/macshell-night-shift-build
MACSHELL_TEST_NIGHT_SHIFT_BINARY=/tmp/macshell-night-shift-build/release/macshell-night-shift python3 -m unittest discover -s tests -p test_night_shift_rust.py
```

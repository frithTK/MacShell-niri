# MacLock boot clock

The helper emits JSON lines with the Linux boot ID and `CLOCK_BOOTTIME` in milliseconds. Unlike `CLOCK_MONOTONIC`, this clock includes time spent suspended. It samples every 250 ms, or once with `--once`, and exits quietly when the reader closes the pipe. MacLock retains its existing watchdog and process restart behavior.

The normal installer builds this helper offline before touching user files, checks its protocol version, and installs it with both MacLock and MacShell, whose timers share the same source. `MacLock/boot-clock.sh` chooses the compatible Rust binary, falling back to the Python helper if it is missing or incompatible during migration. `--python-bridge` opts out of the Rust builds temporarily. This is one part of the migration; other components still require Python.

```sh
cargo test --offline --locked --manifest-path native/boot-clock/Cargo.toml
cargo build --release --offline --locked --manifest-path native/boot-clock/Cargo.toml --target-dir /tmp/macshell-boot-clock-build
MACSHELL_TEST_BOOT_CLOCK_BINARY=/tmp/macshell-boot-clock-build/release/macshell-boot-clock python3 -m unittest discover -s tests -p test_maclock_boot_clock.py
```

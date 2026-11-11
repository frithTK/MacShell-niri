# Menu bar preferences

This service preserves the existing menu bar layout and JSON-lines protocol. It handles legacy visibility, common and per-display layouts, profiles, bindings, validation, recovery and unknown extensions. The shared `native/preferences-store` library provides locking, conflict detection, backups and atomic writes compatible with the Python service. Future schemas stay read-only.

The installer builds and checks the service offline before replacing installed files. Its launcher requires a compatible Rust binary. Python remains for comparison tests and development tools.

```sh
cargo test --offline --locked --manifest-path native/preferences-store/Cargo.toml
cargo test --offline --locked --manifest-path native/bar-preferences/Cargo.toml
cargo build --release --offline --locked --manifest-path native/bar-preferences/Cargo.toml --target-dir /tmp/macshell-bar-preferences-build
MACSHELL_TEST_BAR_PREFERENCES_BINARY=/tmp/macshell-bar-preferences-build/release/macshell-bar-preferences python3 -m unittest discover -s tests -p test_bar_preferences_rust.py
```

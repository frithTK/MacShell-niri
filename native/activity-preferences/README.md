# Activity preferences service

This service manages the existing Activity appearance document and JSON-lines protocol. It uses the bundled schema and the shared `native/preferences-store` library, preserves unknown fields, validates values, detects external changes using SHA-256, and uses the same cooperative file lock as the Python service. Updates are staged, synchronized and atomically renamed; migration and recovery retain a backup of the original file. Future schemas stay read-only.

The installer builds and checks this service offline before replacing installed files. Its launcher uses the compatible Rust binary, falling back to the previous Python implementation during migration. Other components and the installer still require Python.

```sh
cargo test --offline --locked --manifest-path native/activity-preferences/Cargo.toml
cargo build --release --offline --locked --manifest-path native/activity-preferences/Cargo.toml --target-dir /tmp/macshell-activity-preferences-build
MACSHELL_TEST_ACTIVITY_PREFERENCES_BINARY=/tmp/macshell-activity-preferences-build/release/macshell-activity-preferences python3 -m unittest discover -s tests -p test_activity_preferences_rust.py
```

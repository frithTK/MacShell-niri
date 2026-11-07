# Native blur service

This service applies the existing `NativeBlurControl.qml` protocol to the
active MacShell niri profile. It checks the socket peer's user, process
identity and config path; validates a temporary candidate; rechecks the session
and source files; and updates only the managed blur fragment and include. An
advisory lock prevents overlapping Rust writes. The first config backup is
created atomically, and rollback is attempted only while the files still match
the expected contents. A failed sync after a rename is treated as an uncertain result rather
than blindly undoing the other half of the change.

The launcher falls back to the Python service when the Rust binary is missing or
has an incompatible protocol version. Both implementations must remain while
the rest of the migration is in progress.

```sh
cargo test --locked --offline --manifest-path native/native-blur/Cargo.toml
cargo build --locked --offline --manifest-path native/native-blur/Cargo.toml
MACSHELL_TEST_NATIVE_BLUR_BINARY="$PWD/native/native-blur/target/debug/macshell-native-blur" \
  python3 -m unittest discover -s tests -p test_native_blur_rust.py
```

Integration tests use a private fake niri socket and temporary profile. When
niri is available, a real `niri validate` checks an isolated candidate; no
running compositor or user config is changed. The QML probe runs offscreen.

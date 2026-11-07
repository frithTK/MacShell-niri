# Widget preferences service

This service implements the existing widget JSON-lines protocol and uses the
shared `macshell-preferences-store`. It preserves the legacy
`macwidgets/settings.json` location, including the `~/.config` fallback. The
first migration of a nonempty legacy layout waits for a real display identity;
it commits under a lock with a token check and keeps the original backup.
Unsupported future documents and damaged records remain read-only. Resetting a
recoverable document requires an explicit request and saves a recovery copy.

The launcher checks the protocol version and retains the Python implementation
as a temporary fallback. Tests must use a temporary settings directory.

```sh
cargo build --locked --offline --manifest-path native/widget-preferences/Cargo.toml
MACSHELL_TEST_WIDGET_PREFERENCES_BINARY="$PWD/native/widget-preferences/target/debug/macshell-widget-preferences" \
  python3 -m unittest discover -s tests -p test_widget_preferences_rust.py
```

The QML check in that suite runs offscreen if a compatible Quickshell is
available. The offline installation/rollback test is documented in the
project's CI workflow.

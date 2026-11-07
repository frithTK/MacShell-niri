# Locale preferences service

The binary implements the Settings JSON-lines service and `--session`, the
read-only login helper. Both use the same parser and serializer for
`environment.d/90-macshell-locale.conf`; the file remains compatible with the
Python implementation during migration. Locale names are checked against the
current `locale -a` result, and a nonempty `LC_ALL` blocks conflicting changes.
Writes use the existing lock, token and backup conventions.

The installer builds the binary before replacing files. The separate-session
installation also places a copy beside `session-locale.sh`; that wrapper
checks the protocol and falls back to the prior Python helper if needed. An
existing generated login script is refreshed when installing with `--session`.

```sh
cargo build --locked --offline --manifest-path native/locale-preferences/Cargo.toml
MACSHELL_TEST_LOCALE_PREFERENCES_BINARY="$PWD/native/locale-preferences/target/debug/macshell-locale-preferences" \
  python3 -m unittest discover -s tests -p test_locale_session_rust.py
```

These tests use temporary configuration directories and a fake locale registry.
The QML test runs offscreen when a compatible Quickshell is available.

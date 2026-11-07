# Power profiles service

This Rust service uses the system Gio/GLib D-Bus API. It supports the current
and legacy power-profiles-daemon names, confirms profile changes by reading the
daemon back, and owns Game Mode holds only for its D-Bus connection. Replies
from an old name owner are ignored, including when the same unique connection
later reacquires the name. If the outcome of a hold or release is unknown, the
service reports unavailability and exits; closing its connection releases any
holds owned by that connection, as described by the [power-profiles-daemon API](https://upower.pages.freedesktop.org/power-profiles-daemon/gdbus-org.freedesktop.UPower.PowerProfiles.html). The same happens if the daemon owner disappears
while a hold or operation is outstanding; an idle service can reconnect.

The Python implementation remains the fallback when the Rust executable is
missing or has an incompatible protocol version. The build needs Rust 1.85+ and
the system Gio/GLib linker libraries; no separate D-Bus crate is used.

```sh
cargo build --locked --offline --manifest-path native/power-profiles/Cargo.toml
MACSHELL_TEST_POWER_PROFILES_BINARY="$PWD/native/power-profiles/target/debug/macshell-power-profiles" \
  python3 -m unittest discover -s tests -p test_power_rust.py
```

The protocol tests run against a private D-Bus daemon and a synthetic power
service. The QML check is offscreen when Quickshell is available. They do not
change real power profiles or prove hardware-specific behavior.

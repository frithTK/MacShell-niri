# BlueZ discovery transport

This transport executes the discovery state machine through Gio. It is used by
`macshell-bluetooth` (`native/bluez-session`). The owner must supply the current
unique BlueZ name and every owner loss or replacement from the bus watcher, on
the same GLib context, and drain events without reentry.

`Discovery::hold()` / `release_hold()` start or keep LE scanning without the
pairing 30-second deadline. `start()` still uses that deadline. Stop, owner
change and failed/uncertain start clear the hold.

Only references obtained on this connection are stopped. Start and stop calls
have finite timeouts. Since a failed or timed-out call may have been processed,
the transport conservatively emits `CloseConnection` on any call failure. The
owner must actually close that D-Bus connection and rebuild every component
using it before issuing more operations. Dropping the transport while a call or
reference is outstanding also emits this event; the caller is responsible for
closing the connection during teardown even if it no longer drains events.

The test uses a private bus, synthetic adapters and another fake client's
reference. It never operates the system Bluetooth service:

```sh
cargo build --locked --offline --manifest-path native/bluez-discovery/Cargo.toml --examples
MACSHELL_TEST_BLUEZ_DISCOVERY_HARNESS="$PWD/native/bluez-discovery/target/debug/examples/private_discovery_harness" python3 -m unittest discover -s tests -p test_bluez_discovery_rust.py
```

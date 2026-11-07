# BlueZ session and Bluetooth service

One GLib owner watcher coordinates the Agent1 endpoint, asynchronous snapshot
reader and connection-owned discovery transport. It registers the agent with
the current unique owner, reacts to relevant signals from that owner, discards
old snapshots and registration callbacks on owner changes, and cancels pending
authorization when the connection has to close. `poll()` must be called on
the owning main context to drain component events; `tick()` must be called with
monotonic milliseconds for discovery and authorization deadlines.

The caller must provide a dedicated Gio D-Bus connection and keep it alive
until the session is dropped. The session closes that connection on drop.
The session disables Gio's process-exit-on-close behavior and flushes pending
agent replies before closing the connection.
On `CloseConnection`, drop the session promptly and build a new session on a
new connection; do not share that connection with unrelated services. The
test harness uses its own private bus. The service creates its own connection
instead of relying on Gio's shared `g_bus_get_sync` object.

`pair()` performs a user-requested Device1.Pair, verifies Paired or Bonded,
sets and verifies Trusted, connects and verifies Connected. Each asynchronous
step is tied to the owner and operation ticket; cancellation and deadlines
discard stale replies. An ambiguous local Pair timeout sends a best-effort
CancelPairing, while a remote InProgress failure does not cancel another
client's operation. As with any D-Bus operation already sent, cancellation
cannot undo a change the daemon has already applied.

`set_connected()` runs a direct Connect or Disconnect and re-reads Connected
before reporting success. A local timeout and BlueZ's already-in-target-state
errors also trigger a readback. Direct operations and pairing are serialized;
owner changes, cancellation and the operation deadline invalidate old replies.
Cancellation cannot undo a Connect or Disconnect already processed by BlueZ.

`set_power()` first releases this connection's discovery references, reads a
fresh adapter inventory, and validates every adapter's Powered property before
issuing writes. It reads back each changed adapter. Power, pairing, direct
device operations and new discovery requests are serialized. If a power write
has an uncertain outcome, the session requires its connection to close before
further operations. A multi-adapter operation can partially succeed; cancellation
or failure cannot roll back changes already applied by BlueZ.

`macshell-bluetooth` supplies the existing JSON-lines protocol to
`BluetoothControl.qml`; the launcher falls back to Python if the Rust binary
is missing or incompatible. `begin_authorization` is a lower-level helper that
prepares only Agent1. Automated tests use synthetic BlueZ devices; real Bluetooth
hardware is not covered by these tests.

```sh
cargo build --locked --offline --manifest-path native/bluez-session/Cargo.toml --examples
cargo build --locked --offline --manifest-path native/bluez-session/Cargo.toml --bin macshell-bluetooth
MACSHELL_TEST_BLUEZ_SESSION_HARNESS="$PWD/native/bluez-session/target/debug/examples/private_session_harness" python3 -m unittest discover -s tests -p test_bluez_session_rust.py
MACSHELL_TEST_BLUEZ_SESSION_HARNESS="$PWD/native/bluez-session/target/debug/examples/private_session_harness" python3 -m unittest discover -s tests -p test_bluez_pair_rust.py
MACSHELL_TEST_BLUEZ_SESSION_HARNESS="$PWD/native/bluez-session/target/debug/examples/private_session_harness" python3 -m unittest discover -s tests -p test_bluez_device_rust.py
MACSHELL_TEST_BLUEZ_SESSION_HARNESS="$PWD/native/bluez-session/target/debug/examples/private_session_harness" python3 -m unittest discover -s tests -p test_bluez_power_rust.py
MACSHELL_TEST_BLUETOOTH_BINARY="$PWD/native/bluez-session/target/debug/macshell-bluetooth" python3 -m unittest discover -s tests -p test_bluetooth_service_rust.py
```

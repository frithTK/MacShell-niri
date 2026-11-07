# BlueZ snapshot decoding

This crate converts a `GetManagedObjects` reply into the JSON state currently
emitted by the Python Bluetooth service, including known and discovered
devices. The asynchronous reader requests this data from the unique owner and
discards stale replies, applies a timeout, and coalesces overlapping refreshes.
It never changes Bluetooth settings or devices. The owner must feed each loss
and replacement from the bus name watcher on the same GLib context, including
when the unique name is reused. Its epoch is internal to the reader; do not
assume it equals the agent host's epoch. The parser uses GLib case folding to
order names.

The integration test compares real Gio variants against the Python decoder on
a private test bus populated exclusively with synthetic adapters and devices:

```sh
cargo build --locked --offline --manifest-path native/bluez-snapshot/Cargo.toml --examples
MACSHELL_TEST_BLUEZ_SNAPSHOT_HARNESS="$PWD/native/bluez-snapshot/target/debug/examples/private_bus_snapshot" python3 -m unittest discover -s tests -p test_bluez_snapshot_rust.py
MACSHELL_TEST_BLUEZ_ASYNC_HARNESS="$PWD/native/bluez-snapshot/target/debug/examples/async_snapshot_harness" python3 -m unittest discover -s tests -p test_bluez_snapshot_async_rust.py
```

The example is a test harness and requires an explicitly supplied bus address.
This crate is not connected to the running shell.

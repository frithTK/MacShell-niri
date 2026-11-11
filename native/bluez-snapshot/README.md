# BlueZ snapshot decoding

This crate converts a `GetManagedObjects` reply into the JSON state used by
`macshell-bluetooth` (and the Python comparison decoder), including known and discovered
devices. The asynchronous reader requests this data from the unique owner and
discards stale replies, applies a timeout, and coalesces overlapping refreshes.
It never changes Bluetooth settings or devices. The owner must feed each loss
and replacement from the bus name watcher on the same GLib context, including
when the unique name is reused. Its epoch is internal to the reader; do not
assume it equals the agent host's epoch. The parser uses GLib case folding to
order names. Apple BLE manufacturer data (company 0x004C, proximity type 0x07)
supplies left/right/case charge when `org.bluez.Battery1` is absent; Battery1
still wins for the overall percentage until an AACP report arrives.
`parse_aap` decodes connected-host battery frames. Nearby unpaired Apple ads can fill a
single connected Apple audio device whose classic address differs from the
LE identity. JSON includes `batteryLeft` / `batteryRight` / `batteryCase` /
`charging` only when those fields are set, and `appleAudio` for Apple headsets.

The integration test compares real Gio variants against the Python decoder on
a private test bus populated exclusively with synthetic adapters and devices:

```sh
cargo build --locked --offline --manifest-path native/bluez-snapshot/Cargo.toml --examples
MACSHELL_TEST_BLUEZ_SNAPSHOT_HARNESS="$PWD/native/bluez-snapshot/target/debug/examples/private_bus_snapshot" python3 -m unittest discover -s tests -p test_bluez_snapshot_rust.py
MACSHELL_TEST_BLUEZ_ASYNC_HARNESS="$PWD/native/bluez-snapshot/target/debug/examples/async_snapshot_harness" python3 -m unittest discover -s tests -p test_bluez_snapshot_async_rust.py
```

The example is a test harness and requires an explicitly supplied bus address.
The shell talks to this crate through `macshell-bluetooth`, not as a standalone
process. Parser tests: `cargo test --locked --offline --manifest-path native/bluez-snapshot/Cargo.toml`.

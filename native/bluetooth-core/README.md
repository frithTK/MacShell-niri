# Bluetooth state machines

This crate contains the pairing and discovery state machines used by
`macshell-bluetooth` (`native/bluez-session`). Python `bluetooth_service.py`
remains only as a fallback when the Rust binary is missing or reports an
incompatible protocol version.

The transport must use the unique BlueZ owner provided by the bus, register
the agent for that owner, validate the selected device and carry operation
epochs and tokens through every asynchronous callback. Pairing only advances
to trust after the device's paired state is confirmed, and only advances to
connect after trust succeeds.

Discovery effects belong to one D-Bus connection. Execute `Stop` only for the
reference acquired by that connection. When `StartDiscovery` has an uncertain
result, call `start_uncertain`; an uncertain stop also yields
`CloseConnection`. Close the old connection before calling
`connection_replaced`. Owner changes, cancellation and late results must be
forwarded to the state machines. A caller must give asynchronous operations
finite timeouts and classify definitive rejection separately from an unknown
result.

`start()` runs a 30-second pairing search. `hold()` keeps LE listening without
that deadline so the Batteries widget can read Apple advertisements; `stop`
and owner changes clear the hold. Pairing search and the hold share the same
adapter references.

Run `cargo test --locked --offline --manifest-path native/bluetooth-core/Cargo.toml`.
The tests use synthetic paths and do not contact Bluetooth hardware.

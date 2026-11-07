# Bluetooth state machines

This crate contains the pairing and discovery state machines for the ongoing
Rust migration. It is not connected to the shell; the Python Bluetooth service
remains in use.

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

Run `cargo test --locked --offline --manifest-path native/bluetooth-core/Cargo.toml`.
The tests use synthetic paths and do not contact Bluetooth hardware.

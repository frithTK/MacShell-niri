# Gio FFI bridge

This crate shares the narrow system GLib/Gio ABI declarations used by the Rust
power profiles backend and the BlueZ crates (`bluez-agent`, `bluez-snapshot`,
`bluez-session`). It is an unsafe FFI boundary, not a general-purpose safe
binding. The caller is responsible for connection, main-context, callback and
variant lifetimes. In particular, a GDBus method invocation delivered to a
callback must eventually be consumed by one return operation, including
cancellation and teardown paths. `Variant::variant()` unwraps a boxed GVariant
and `Variant::bytes()` copies `ay` payloads used for BlueZ `ManufacturerData`
(`a{qv}`). See the crate-level documentation and the Agent1 private-bus
integration tests.

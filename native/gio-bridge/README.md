# Gio FFI bridge

This crate shares the narrow system GLib/Gio ABI declarations used by the Rust
power profiles backend and the experimental BlueZ agent. It is an unsafe FFI
boundary, not a general-purpose safe binding. The caller is responsible for
connection, main-context, callback and variant lifetimes. In particular, a
GDBus method invocation delivered to a callback must eventually be consumed by
one return operation, including cancellation and teardown paths. See the
crate-level documentation and the Agent1 private-bus integration tests.

# NetworkManager Wi-Fi core

Pure, non-I/O logic for the planned Rust Wi-Fi service. It covers access point
security flags, byte-exact SSID and saved-profile selection, password syntax,
and authorization of a SecretAgent request against the current operation and
NetworkManager owner. The current Python service remains the active backend.

`new_profile::prepare` validates non-secret metadata for a newly selected
network. It preserves the original SSID bytes and derives the display string;
SSID containing NUL is rejected because the existing connection ID is a D-Bus
string. The input password is borrowed for validation and is not retained in
the returned plan or error. A caller must supply a fresh CSPRNG-generated UUID;
format validation alone cannot establish randomness. The associated helper
`network-snapshot::identity::new_uuid` obtains it from the Linux kernel.

The SecretAgent state machine does not hold passwords. Its caller must own and
erase secrets, export the D-Bus agent, supply verified owner/registration events,
reject or complete every pending invocation, and respect `discard_provided`
when NetworkManager requests a new secret. Owner loss, re-registration and
operation/prompt identity must invalidate stale callbacks. The state machine is
not itself a D-Bus endpoint and does not manage activation or timeouts.

`activation` models a single pending activation and cancellation, but does not
perform D-Bus operations. A returned active-connection path is not evidence that
the connection is exclusive to the operation. The transport may mark it owned
only with actual proof; otherwise cancellation fails closed without disconnecting
it. It must also serialize and fence individual observation requests, including
late replies with the same purpose, by its own request IDs. `CloseUncertain`
requires closing the dedicated connection and discarding the activation state;
the surrounding service must fence callbacks from the discarded instance.
Checking an activating state and sending DeactivateConnection are separate
operations, so the state can change between them.

The tests run offline. `tests/test_network_core_rust.py` compares the pure
selection and validation functions with the current Python implementation on
synthetic inputs; `examples/compat_harness.rs` exists only for that comparison.

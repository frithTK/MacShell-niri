# NetworkManager SecretAgent endpoint

This crate exports the NetworkManager SecretAgent D-Bus object for the planned
Rust Wi-Fi service. It is not registered with the real NetworkManager or wired
into MacShell. `AgentHost` watches the unique owner and registers the endpoint
on a dedicated Gio connection. It reports owner and registration changes on
the connection's GLib context. On owner loss, a registration timeout or an
uncertain reply, the caller must close that connection and recreate the host;
it must also close the connection after dropping the host. Drain both event
channels outside callbacks, and erase secrets for the reported abandoned request.

Each activation is bound to a ticket, UUID and optional saved-profile path.
Only the current verified owner may request a secret, cancel a request or call
the other agent methods. A prompt or initial-secret request yields a numbered
event containing no password. The owner supplies the secret only when replying
to that exact ticket and delivery; stale replies cannot satisfy a later request.
Owner change, cancellation, shutdown or failure to deliver an event terminates
the pending D-Bus invocation. The owning service must enforce operation deadlines
and erase its own secrets on completion, cancellation and `discard_provided`.

The endpoint does not persist passwords: `SaveSecrets` fails rather than falsely
acknowledging storage, and `DeleteSecrets` is a no-op. It erases its temporary C
copy after replying, but the caller, Gio and D-Bus may hold other copies; the
endpoint cannot promise that those are erased. No passwords are sent in events,
error messages or logs. The current Python Wi-Fi backend remains active.

`examples/private_agent.rs` and `tests/test_network_agent_rust.py` are test-only.
They require an explicit private D-Bus address and use synthetic secrets. The
integration suite covers sender and identity checks, interaction flags, stale
responses, owner changes, cancellation, drop, and a missing event consumer.
`examples/private_host.rs` and `tests/test_network_agent_host_rust.py` exercise
registration, refusal, timeouts, late replies and owner loss on a private bus.

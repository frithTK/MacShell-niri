# BlueZ Agent1 endpoint

This crate exports the Gio D-Bus Agent1 object for the Rust Bluetooth migration.
It is not registered with the system BlueZ service or connected to the current
shell. `AgentHost` watches the unique owner and registers with that specific
owner's AgentManager. Owner changes invalidate outstanding registration and
pairing results, and registration has a finite timeout. The caller must feed
pairing results back to the agent and process emitted events on the owning
GLib main context, without reentry. The `Agent::new` and `AgentHost::new`
safety contracts require the connection and context to outlive the host. Each
deferred invocation is answered or canceled exactly once.

The `private_bus_harness` example is for tests only. It requires an explicitly
provided `DBUS_SYSTEM_BUS_ADDRESS` and an already running fake `org.bluez`;
it does not perform adapter operations. For the integration test:

```sh
cargo build --locked --offline --manifest-path native/bluez-agent/Cargo.toml --examples
MACSHELL_TEST_BLUEZ_AGENT_HARNESS="$PWD/native/bluez-agent/target/debug/examples/private_bus_harness" python3 -m unittest discover -s tests -p test_bluez_agent_rust.py
MACSHELL_TEST_BLUEZ_REGISTRATION_HARNESS="$PWD/native/bluez-agent/target/debug/examples/registration_harness" python3 -m unittest discover -s tests -p test_bluez_registration_rust.py
```

The test creates its own private bus and fake owner; it never uses the real
Bluetooth service. A complete service, discovery transport, installer and QML
integration still need to be implemented and tested before switching backends.

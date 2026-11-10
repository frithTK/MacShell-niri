# BlueZ Agent1 endpoint

This crate exports the Gio D-Bus Agent1 object used by `macshell-bluetooth`.
It is not registered with BlueZ on its own; `bluez-session` owns the connection
and registers the agent with the current unique owner. `AgentHost` watches that
owner and registers with that specific owner's AgentManager. Owner changes
invalidate outstanding registration and pairing results, and registration has a
finite timeout. The caller must feed pairing results back to the agent and
process emitted events on the owning GLib main context, without reentry. The
`Agent::new` and `AgentHost::new` safety contracts require the connection and
context to outlive the host. Each deferred invocation is answered or canceled
exactly once.

The `private_bus_harness` example is for tests only. It requires an explicitly
provided `DBUS_SYSTEM_BUS_ADDRESS` and an already running fake `org.bluez`;
it does not perform adapter operations. For the integration test:

```sh
cargo build --locked --offline --manifest-path native/bluez-agent/Cargo.toml --examples
MACSHELL_TEST_BLUEZ_AGENT_HARNESS="$PWD/native/bluez-agent/target/debug/examples/private_bus_harness" python3 -m unittest discover -s tests -p test_bluez_agent_rust.py
MACSHELL_TEST_BLUEZ_REGISTRATION_HARNESS="$PWD/native/bluez-agent/target/debug/examples/registration_harness" python3 -m unittest discover -s tests -p test_bluez_registration_rust.py
```

The test creates its own private bus and fake owner; it never uses the real
Bluetooth service. The live helper is `macshell-bluetooth` in `native/bluez-session`.

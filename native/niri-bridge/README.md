# Experimental Rust niri bridge

This is the Rust implementation of the persistent bridge used by `MacShell/Niri.qml`. The installer builds it by default during the transition to Rust; the existing Python bridge remains an explicit rollback option. The `timed_modes.py` and `recording_control.py` services still import the Python request helper. Replacing this process does not yet remove the project's Python dependency.

The bridge connects to the `NIRI_SOCKET` Unix socket, requests outputs, subscribes to the niri event stream and emits JSON-lines snapshots and title deltas on stdout. It accepts action requests over stdin and uses separate request connections; diagnostics go to stderr. It keeps the existing 33 ms coalescing and 30 s output refresh, with an earlier output refresh following workspace/config changes. It resets the retry delay after reconnecting. It has no Qt dependency and does not require elevated privileges.

Each connection gets a random `bridgeSession`; QML includes it in commands and rejects updates from an old session. Commands from a different session are discarded. Action connections also verify Linux `SO_PEERCRED` and process start time against the event-stream peer before sending, so a replaced compositor cannot receive a command meant for the old one. Commands are never automatically retried; if niri executes a command but its response is lost, its result remains unknown. The `--replay` argument is a test-only JSON-lines interface for synthetic state cases.

`MacShell/niri-bridge.sh` chooses exactly one implementation at startup and verifies the Rust protocol version. If the Rust binary is absent or incompatible, automatic mode uses Python; an explicitly requested Rust mode fails instead. Once a bridge has started, it is restarted rather than silently switching implementations. To explicitly install the legacy version during migration, use `bash install.sh --python-bridge`; the usual `bash install.sh` builds Rust. Build failure occurs before the installer replaces user files, and rollback restores the previous shell directory and its bridge.

## Build and check

Requires Rust 1.85 or newer, Cargo and Linux. The lockfile pins dependencies. Builds do not install anything:

```sh
cargo build --release --locked --manifest-path native/niri-bridge/Cargo.toml --target-dir /tmp/macshell-niri-rust-build
cargo test --locked --manifest-path native/niri-bridge/Cargo.toml --target-dir /tmp/macshell-niri-rust-build
MACSHELL_NIRI_RUST_BINARY=/tmp/macshell-niri-rust-build/release/macshell-niri-bridge \
  python3 -m unittest discover -s tests -p test_niri_rust_compat.py
```

The compatibility tests use only artificial events and a private fake socket. They compare state, title deltas, commands and reconnects, check stale session rejection, and use distinct test compositor processes to verify that commands do not go to a replacement peer. A real niri integration check creates an isolated nested compositor with temporary settings and synthetic windows; it refuses to run against the parent niri socket:

```sh
python3 scripts/check-niri-bridge-native.py python --crash
python3 scripts/check-niri-bridge-native.py /tmp/macshell-niri-rust-build/release/macshell-niri-bridge --crash
```

It checks window and workspace membership, Dock/switcher models, title updates, a focus command, close, and restart after killing only the test bridge. It does not validate physical monitor hotplug, all capture paths or a real compositor crash.

## Measurement

`scripts/benchmark-niri-bridges.py` compares the two processes against a private artificial niri, alternating their order. It reports process CPU, PSS, startup and event-to-output latency. The separate `--measure` mode of `check-niri-bridge-native.py` measures the process tree of the isolated test shell; it excludes niri itself, PipeWire and the rest of the desktop. Both use synthetic window names; neither records user window titles.

The initial local comparison showed lower memory use for the Rust bridge itself, while the short whole-shell measurements overlapped. These synthetic results do not establish an improvement for an installed desktop. Kernel tick granularity, shared-memory accounting, process churn and scene differences must be considered when interpreting a run.

To repeat the synthetic bridge benchmark and individual isolated shell measurements:

```sh
python3 scripts/benchmark-niri-bridges.py --rust /tmp/macshell-niri-rust-build/release/macshell-niri-bridge --seconds 5 --rounds 3 --windows 8 --output /tmp/niri-bridge-benchmark.json
python3 scripts/check-niri-bridge-native.py python --measure /tmp/niri-python-shell.json
python3 scripts/check-niri-bridge-native.py /tmp/macshell-niri-rust-build/release/macshell-niri-bridge --measure /tmp/niri-rust-shell.json
```

The measurements above refer to the earlier prototype, before the session protocol was added. Physical monitor hotplug, several physical monitors and more niri versions still need hardware/version coverage; Python remains available as a transition fallback while those cases are evaluated.

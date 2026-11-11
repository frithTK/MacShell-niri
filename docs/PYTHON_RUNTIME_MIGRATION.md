# Python runtime migration inventory

The default installer builds Rust components and marks newly installed shell
and lock profiles Rust-only. Source launchers and the generated `macshell-niri`
session launcher never invoke Python: a missing or incompatible Rust binary
fails with an error. Python service modules remain in the tree for comparison
tests, development tools and old snapshots.

## Runtime paths

- `MacShell/JsonService.qml` requires a launcher and reports a configuration
  error instead of invoking Python directly. Its application callers and the
  Stickies fixture use explicit launchers. Bluetooth uses `macshell-bluetooth`
  when the binary reports protocol `macshell-bluetooth 1`; otherwise the
  launcher fails.
- Source launchers in `MacShell/`, `MacLock/` and session helpers in `scripts/`
  exec the matching `*-rust` binary or exit 1. They do not check
  `.macshell-rust-only` and they never `exec python3`.
- `MACSHELL_NIRI_BRIDGE_BACKEND` accepts `auto` or `rust`. Any other value,
  including `python`, is an invalid selection.
- A plain installation still preserves an existing session profile on disk.
  Newly generated `macshell-niri` and session helpers require the Rust
  supervisor; install with `--session` from outside MacShell to migrate old
  Python session files. Rollback can restore a previous Python-dependent
  snapshot.
- The Rust installer excludes Python source files when copying the shell and
  lock profiles and rejects any installed `.sh` that still mentions Python.
  Legacy `.py` files remain in the checkout for unit tests.
- The Rust installer's `--check` checks GStreamer elements without invoking
  Python. Development tools, `scripts/validate.sh` and unittest still use
  Python. Nested native checks that copy a checkout `MacShell/` need the
  matching `*-rust` binaries beside the launchers.
- `install.sh --python-bridge` remains an explicit failure.

## Verification and remaining work

- `MACSHELL_TEST_REAL_COMPONENTS=1 cargo test --locked --offline --manifest-path native/installer/Cargo.toml --test legacy_session` tests failure recovery, session migration and rollback from a synthetic legacy profile with all real offline-built Rust components, including the AirDrop service. It checks shell and lock profiles contain no Python source and that legacy files return after failure and rollback. It executes installed preflight, supervisor check and locale helpers and verifies missing helpers fail without invoking Python. System registration and compositor commands are fixtures. This does not verify a real login or an actual AirDrop transfer.
- `tests/test_rust_only_launchers.py` checks that runtime launchers never
  contain `exec python3` and that missing or incompatible Rust binaries fail
  without invoking Python. The opt-in
  `MACSHELL_TEST_INSTALL_NO_PYTHON=1 /usr/bin/python3 -m unittest discover -s tests -p test_installer_no_python.py -v`
  builds real binaries offline, installs a separate temporary session, checks
  preflight, exercises the shell in a verified nested niri and rolls back with
  no Python executable on PATH. The test driver itself uses Python; systemd
  and desktop registration are fixtures. Set `MACSHELL_TEST_QS_BIN` if the
  compatible Quickshell runtime is not in the default MacShell runtime path.
- Python `*_service.py` modules are kept for unittest comparison. Removing them
  from git is a later cleanup.
- A real SDDM login and physical-device acceptance still need verification.
  Restoring an old snapshot can restore Python-dependent components until the
  profile is reinstalled.

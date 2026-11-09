# Python runtime migration inventory

The default installer builds Rust components and marks newly installed shell
and lock profiles Rust-only. A separate session installation marks its session
helpers Rust-only as well. In these profiles, unavailable or incompatible
Rust binaries fail with an error instead of silently invoking Python.

## Remaining runtime paths

- `MacShell/JsonService.qml` now requires a launcher and reports a configuration
  error instead of invoking Python directly. Its application callers and the
  Stickies fixture use explicit launchers.
- Legacy source launchers retain Python fallback for unmarked profiles, so old
  snapshots remain usable. Rust-installed shell and lock launchers remove that
  fallback and fail if their Rust binary is unavailable or incompatible.
- A plain installation preserves an existing session profile, which can still
  require its legacy Python supervisor. Install with `--session` to migrate
  the session helpers as well; do so from outside the MacShell session.
- Rust session installation generates Rust-only helper launchers and no longer
  copies session Python helpers. Existing legacy files are preserved, and a
  rollback restores the previous profile. Legacy source launchers remain for
  old profiles; `install.sh --python-bridge` now explicitly fails.
- The Rust installer also excludes Python source files when copying the shell
  and lock profiles. Their previous contents are included in the installation
  snapshot and restored on failure or rollback. Legacy source files remain for
  development, comparison tests and old installations.
- The Rust installer-generated `macshell-niri` launcher checks the session
  profile's `.macshell-rust-only` marker before its direct legacy supervisor
  fallback. A missing helper in a marked profile fails instead of invoking
  Python; unmarked legacy profiles retain their existing fallback. A Rust
  test covers both paths and the installed shell helper's precedence. The
  previously installed launcher is not changed until a future installation.
- The Rust installer's `--check` checks GStreamer elements without invoking
  Python. The legacy Python installer has its own dependency checks.
  Development tools and tests still invoke Python.

## Verification and remaining work

- `MACSHELL_TEST_REAL_COMPONENTS=1 cargo test --locked --offline --manifest-path native/installer/Cargo.toml --test legacy_session` tests failure recovery, session migration and rollback from a synthetic legacy profile with all real offline-built Rust components, including the AirDrop service. It checks shell and lock profiles contain no Python source and that legacy files return after failure and rollback. It executes installed preflight, supervisor check and locale helpers and verifies missing helpers fail without invoking Python. System registration and compositor commands are fixtures. This does not verify a real login, an actual AirDrop transfer, or removal of legacy fallbacks.
- `tests/test_rust_only_launchers.py` checks missing and incompatible Rust
  binaries in legacy profiles and with file, directory and dangling-symlink
  Rust-only markers. The opt-in
  `MACSHELL_TEST_INSTALL_NO_PYTHON=1 /usr/bin/python3 -m unittest discover -s tests -p test_installer_no_python.py -v`
  builds real binaries offline, installs a separate temporary session, checks
  preflight, exercises the shell in a verified nested niri and rolls back with
  no Python executable on PATH. The test driver itself uses Python; systemd
  and desktop registration are fixtures. Set `MACSHELL_TEST_QS_BIN` if the
  compatible Quickshell runtime is not in the default MacShell runtime path.
- A real SDDM login and physical-device acceptance still need verification.
  Historical session fallback can still require Python until `--session` is run;
  restoring an old snapshot can likewise restore Python-dependent components.

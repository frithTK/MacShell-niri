# System statistics sampler

This read-only Linux helper supplies the existing JSON-lines `SystemStats` service. It samples CPU, memory, network, disk, root capacity and CPU temperatures. Rates are reseeded after a suspend, a long gap, CPU topology change, device change or configuration update. Automatic network selection uses physical interfaces; root disk mapping does not guess for ambiguous mounts or multi-device Btrfs.

The installer builds this program offline and checks its protocol before replacing any files. `MacShell/system-stats.sh` selects a compatible Rust binary or the previous Python implementation during migration. `--python-bridge` temporarily skips all Rust builds. Other services and the installer still require Python.

```sh
cargo test --offline --locked --manifest-path native/system-stats/Cargo.toml
cargo build --release --offline --locked --manifest-path native/system-stats/Cargo.toml --target-dir /tmp/macshell-system-stats-build
MACSHELL_TEST_STATS_BINARY=/tmp/macshell-system-stats-build/release/macshell-system-stats python3 -m unittest discover -s tests -p test_system_stats_rust.py
```

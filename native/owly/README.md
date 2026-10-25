# Owly adapter

The radio and AirDrop protocol come from MIT-licensed [Owly](https://github.com/t4t5/owly), pinned at `2e9b2b0228432d5e402a9c90a031b419960d0bd1` (0.4.0). `macshell-cli.patch` includes `macshell.rs` in its existing AirDrop module and adds a hidden `macshell` CLI command. No upstream radio, TLS, archive or protocol implementation is changed.

`scripts/build-airdrop-backend.sh` fetches that revision, applies the patch, copies the adapter and builds `owly`/`owlyd`. It installs nothing. `MACSHELL_OWLY_BUILD_DIR` selects another build directory.

The machine interface writes JSON lines on stdout and diagnostics on stderr. `macshell capabilities` reports protocol 1. Radio, browse, send and receive each use an owned process; only radio acquires a D-Bus lease. The receiver emits an ID for each offer and accepts JSON replies with the matching ID. Missing, stale and timed-out replies decline; the Python owner additionally scopes IDs to its session epoch. Sender success requires the native Delivered outcome. Incoming links are displayed and never opened.

Before Acquire, the radio command reads the current capability report and requires a ready Shared mode. Exclusive, Active monitor, unknown and incomplete reports fail before acquiring the adapter. The Python owner independently enforces the same mode policy; a legacy consent flag cannot bypass it. `cargo test --release --locked -p owly-cli ms_policy_tests` checks this guard without acquiring hardware.

The Arch/CachyOS `PKGBUILD` packages a reviewed build tree selected by `MACSHELL_OWLY_TREE`. It uses upstream's installation layout, service hardening, policy, licenses, NetworkManager and link configuration; adds the adapter and source revision to its documentation; and does not acquire a radio during installation. The system service is activated by D-Bus. This package conflicts with an existing `owly` package and must be reviewed before installation.

Native regression:

```bash
python3 scripts/check-airdrop-native.py --binary /path/to/owly
```

It creates a user/network namespace with two veth interfaces, disconnected from the host. The real CLI exchanges a test file over TLS, rejects stale approval, declines without writing, reports progress and verifies delivered bytes. It needs `unshare` and `ip`; it never acquires a Wi-Fi radio. Python fixtures and QML interaction tests cover the owner and UI separately. Physical iPhone discovery, transfers and restoration of the real Wi-Fi adapter require a deliberate hardware check.

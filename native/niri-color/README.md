# niri color picker

This one-shot helper runs only when the user invokes the menu bar color picker.
It asks niri for a color, copies the resulting `#RRGGBB` value with `wl-copy`,
and displays the existing notification. Canceling does not touch the clipboard.
Responses are bounded and invalid results are rejected before copying; the
interactive picker has no fixed deadline while the user is choosing.

The launcher checks the binary protocol and fails if the Rust binary is missing
or incompatible. Python `niri_tools.py` remains for comparison tests.

```sh
cargo build --locked --offline --manifest-path native/niri-color/Cargo.toml
MACSHELL_TEST_NIRI_COLOR_BINARY="$PWD/native/niri-color/target/debug/macshell-niri-color" \
  python3 -m unittest discover -s tests -p test_niri_color_rust.py
```

Tests replace niri, clipboard and notifications with local fixtures. The QML
test executes the menu bar's actual action offscreen with those fixtures; no
real color is picked and no user clipboard is modified.

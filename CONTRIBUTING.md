# Contributing

This repository maintains the niri port of [0-ss/MacShell](https://github.com/0-ss/MacShell). Bug reports, focused fixes and documentation improvements are welcome. Open an issue before substantial UI or architecture work so the expected behavior can be discussed.

Version 1.0.0 starts from one initial release commit. If you have a checkout from before that release, clone a fresh copy and transfer your local changes; see [source history](docs/HISTORY.md).

## Source layout

| Directory | Contents |
| --- | --- |
| `MacShell/` | Desktop QML, GLSL shaders and Python helpers |
| `MacLock/` | Separate PAM/session-lock configuration |
| `scripts/` | Installer, backup/recovery, session startup and validation |
| `config/` | niri and desktop-session templates |
| `tests/` | Python regressions, QML tests and isolated Quickshell harnesses |
| `docs/` | User guides, screenshots and runtime patch |

Use four-space indentation for QML and Python, and match the surrounding shell code. Keep niri integration in the shared adapter and helpers. Preserve the upstream MIT notices. Do not add a Hyprland dependency or restore the upstream automatic updater.

Changes in a checkout do not update the installed desktop. Keep installation, activation, session selection and package installation separate from development checks.

## Portable checks

Portable checks also validate RU/EN catalog parity, duplicate IDs, plural forms, named parameters and literal call IDs. New UI uses Locale/I18n with stable IDs; actions, window identities and stored values stay independent of translated labels. See [localization contracts and source data](docs/LOCALIZATION.md).

The backend suite needs Linux, Python 3.11+, PyGObject/Gio, Pillow, GStreamer/GstVideo introspection with the base/good plug-ins, `dbus-daemon`, `ffmpeg`/`ffprobe` and `desktop-file-validate`. Ubuntu package names are recorded in the [CI workflow](.github/workflows/ci.yml). When PyGObject is installed by the OS package manager, use the matching system Python.

```bash
bash scripts/check-portable.sh
```

This runs Python regressions, Python compilation, shell syntax checks and desktop-entry validation. `MACSHELL_TEST_PYTHON=/path/to/python3` selects another interpreter. Tests create temporary configuration and private IPC/D-Bus services; the environment must allow local Unix sockets. Checks requiring niri or Quickshell are skipped when those tools are unavailable.

Focused example:

```bash
python3 -m unittest discover -s tests -p 'test_bluetooth.py' -v
```

## QML interaction checks

Localization probes: `check-system-language-native.py --capture /tmp/language-preview` chooses/saves Russian through real Settings, visits every pane, checks another open app, retained state, emoji search and stable alarm Save/snooze/Stop, then starts a new process with the saved locale. Settings/cache/home are private and playback is forbidden. `check-maclock-language.py` (included in full validation) checks production LockScreen offscreen in preview and asserts real lock/PAM remain inactive while shared preferences change RU/EN. `check-notifications-native.py` clicks owned mock cards, including synchronous dismissal. Run GUI probes sequentially.

With Qt 6.9+ Declarative, Quick Controls, Quick Effects and Quick Test installed (`RectangularShadow` requires Qt 6.9):

```bash
bash scripts/check-qml.sh
```

This runs all tests in `tests/qml` offscreen with software rendering and temporary configuration/cache directories. It does not need niri, Quickshell or an active desktop session. The runner is discovered under `QT_ROOT_DIR`, through `qmltestrunner6` on `PATH`, or in the system Qt 6 directory before falling back to an unversioned runner. `MACSHELL_QML_TEST_RUNNER=/path/to/qmltestrunner` selects a specific Qt installation. Use a Qt 6 runner when Qt 5 is also installed.

GitHub Actions runs the portable checks and QML tests as separate jobs on pushes and pull requests. The QML job uses Qt 6.9.3 with a pinned installation action and a cached Qt download.

## Full validation

With the [runtime dependencies](docs/INSTALL.md#requirements), compatible Qt/Quickshell, Qt Test, Qt shader tools, niri, `desktop-file-validate` and `rg` installed:

```bash
bash scripts/validate.sh
```

The full suite includes both check scripts above, niri configuration validation, QML and shader compilation and isolated Quickshell adapter/service checks. It writes generated files to temporary directories and does not activate the installed desktop.

`python3 scripts/check-widget-lifecycle.py` uses real MacWidgets/WidgetVisual components with deterministic owned Weather/LRCLIB workers, fake media and a logical output offscreen. It covers shared desktop/mirror subscriptions, frozen snapshots, clock/position/refresh stopping, fullscreen/overview, global disable/enable, late responses and 20 mount/unmount cycles. It confirms that worker PIDs exit after the last consumer, without network or user-media access. Full validation includes it.

`python3 scripts/check-activity-widget-native.py` exercises S/M/L Activity cards through the real shell, transactional writer and shared `/proc` sampler with isolated settings and unavailable device buses. It checks metrics Apply/conflict, independent duplication, shared mirrors, operation with the menu bar disabled, details on the card's output, source release/restart, fullscreen/overview and stale data. It deliberately opens temporary cards and popovers in the active Wayland session. `check-widget-input-native.py` also verifies actual compositor clicks on Activity and releases its native input region after removal. `bash scripts/preview-activity-widget.sh` captures every size in both themes with demonstration data and no sampler.

`python3 scripts/check-batteries-widget-native.py` tests Batteries through the real desktop, editor and writer in niri with isolated laptop/Bluetooth inputs. It covers unknown/zero/full charge, duplicate addresses/names, device Apply/Cancel/conflict, independent duplication, mirror sharing, device/adapter/service loss and recovery, disabled desktop editing, fullscreen/overview and 20 mount cycles. Discovery attempts fail the fixture; it does not touch real devices. The native input check separately confirms Batteries is click-through outside Arrange. `bash scripts/preview-batteries-widget.sh` captures both themes with sample data. `python3 scripts/measure-batteries-widget.py --output /tmp/batteries-cost.json` measures four Large cards against a static existing Calendar, using synthetic shared data rather than devices.

For optional real-Wayland menu geometry checks with Qt Test available, run `python3 scripts/check-bar-native.py`. It opens temporary panels, uses isolated settings and unavailable D-Bus/niri endpoints, and clicks only its own controls. It checks menus across three zones and compact application-menu navigation; it does not establish hardware availability or physical multi-monitor behavior. Do not run it as an idle background check on someone else's active desktop.

`python3 scripts/check-widget-native.py` separately checks migration, legacy IDs, unknown records and the defaults/resize/move/add/delete/reload cycle through the real desktop controller and writer. It briefly opens click-through widget layers with temporary settings and disconnected system services. The native layer backend requires an active Wayland session; it is not part of the offscreen suite. Full offscreen validation also checks two WidgetPreferences controllers against one temporary file.

`python3 scripts/check-widget-input-native.py` checks real compositor input routing for six Players, including Duplicate/Remove/Undo through the native editor, click-through gaps/passive cards, visibility, availability, transforms, moves, empty masks, Edit dragging, context lifetime and Done/Escape with focus restoration, and native region reflow after reserved-area changes. It needs `cc`, `pkg-config`, Wayland client development files, Qt Test, niri with wlr-virtual-pointer v2 and an output of at least 900×800 logical pixels. The harness uses temporary settings, fake media and its own guarded front/back panels; the pointer and keyboard events target only those surfaces. It briefly opens a normal editor and moves the pointer, so run it as a deliberate native check rather than an idle background task. `--list-protocols` only reports protocol availability. No new runtime dependency is required by the shell.

`python3 scripts/check-widget-outputs.py` checks the real controller and transactional writer using synthetic logical displays without desktop surfaces. It covers reorder, reactive reserved areas, disconnect/reconnect, add/transfer/resize, independent duplicates, unplaced/future records, nested unknown fields, multi-step removal undo, closing during a save and conflicts with a second writer. Failed moves/resizes/duplicates do not write settings; failed removals create no undo entry, and failed undo remains retryable. Full validation includes it. The model suite separately covers fractional/rotated geometry and ambiguous identities. These checks do not establish physical multi-monitor behavior.

`python3 scripts/check-theme-native.py` checks live theme changes through Settings, Control Center and View with a temporary shell and isolated settings/devices. It also exercises already-open panes/Clock/widgets, saved theme values, stale samples, the transparent bar over its own light/dark top surfaces and Configure opening the selected instance in Settings. Appearance checks cover a write-free draft, atomic Apply, local overrides surviving shell theme/font changes, matching desktop/glass renderers and Reset restoring inheritance. `--capture-dir /path` writes sample-data captures, including real instance controls and Player appearance in both themes. See [appearance behavior and diagnostics](docs/APPEARANCE.md).

`python3 scripts/measure-live-shell.py --output /tmp/macshell-current.json` measures CPU, PSS/RSS and available DRM engine counters for the installed shell process tree. The default phase only reads state; explicit `idle`/`activity` phases change the active menu. See [measurement scope, reproduction and observations](docs/PERFORMANCE.md). `bash scripts/preview-stats.sh` regenerates both Activity graph screenshots using demonstration data.

Performance regressions include real title-delta IPC and mixed geometry updates (`test_niri.py`/`tests/adapter.qml`), a private NetworkManager bus with signal-only changes, and offscreen marquee pause/resume checks. When Quickshell is available, `test_brightness_native.py` uses real FileView reads against temporary sysfs-shaped files to check external changes, maximum values, device return and the absence of recurring discovery processes. It never writes hardware; portable environments without Quickshell skip this one check. Profiling sessions and compiler/debugger overhead must be kept separate from CPU acceptance measurements.

`python3 scripts/check-recording-native.py` records its own opaque surface and private virtual audio with the real recorder/helper. It checks video packets beyond ten seconds, buffered output, all four audio modes and target removal. It needs a live niri/Quickshell/PipeWire session; PulseAudio recorder builds additionally need pipewire-pulse and pactl. It does not capture the user's microphone or application audio, change default devices or keep test media. Use `--installed` to exercise the installed backend and `--modes none system` for a shorter check. Run it deliberately rather than as an idle desktop task.

Add a regression for behavior changes. For visual changes, include screenshots of both themes and check the affected interactions in a real niri session. Use demonstration data rather than personal notifications, device names or network information in public screenshots.

For README media, `python3 scripts/capture-showcase.py --output-dir /tmp/macshell-showcase --gif` captures production QML in a separate nested niri with isolated settings and demonstration services. It deliberately opens/resizes only its owned compositor window, captures both themes and encodes a silent GIF/MP4. The presentation preset uses stronger glass than the defaults; document that distinction. See the [capture recipe, exact settings and publication checks](docs/SCREENSHOTS.md).

For UxPlay 1.73.7 PIN compatibility, see the [external runtime patch and reproduction guide](docs/UXPLAY_RUNTIME.md). `scripts/check-uxplay-pin-native.py --source /path/to/UxPlay --binary /path/to/uxplay` exercises a real SRP exchange, including correct/wrong codes, server proof verification and malformed proof lengths. It needs UxPlay sources, a C compiler, pkg-config/OpenSSL development files and local socket/mDNS access; it uses temporary keys, a fake media sink and random test ports. It does not start the installed MacShell receiver or establish physical iPhone rendering.

AirDrop uses a [pinned Owly adapter](native/owly/README.md). `bash scripts/build-airdrop-backend.sh` only builds it. `python3 scripts/check-airdrop-native.py --binary /path/to/owly` checks actual TLS transfers in an isolated user/network namespace with a veth pair; it needs `ip` and `unshare`, and does not acquire a host radio. CI also tests the Shared-only guard before Acquire. Exclusive/Active monitor are blocked after a real Wi-Fi/call interruption; never test that guard by acquiring the user's radio. Physical iPhone checks use a supported Shared setup, with explicit user participation.

Installer changes must preserve existing user files and recoverable backups. Check installation and rollback in temporary paths. MacLock authentication, screen capture, audio routing and hardware controls also need focused real-session validation; automated fixtures do not establish that a particular device or PAM configuration works.

`python3 scripts/check-calculator-native.py --capture docs/images` checks the real Calculator window, buttons/keyboard, Russian utility search, Dock opening, separate window identities, UI release and all four Clock sections. It captures three Calculator modes in both themes. Calculator QML regressions cover bounded expression parsing, mathematical errors, units, session history/memory and clipboard signals.

`python3 scripts/check-widget-arrange-native.py --capture docs/images` exercises production layer promotion above open Settings/Calculator, the opaque wallpaper fallback, the embedded 40px toolbar, hiding it during dragging, both themes and release on exit. It confirms that entering/selecting/exiting does not save positions. `check-widget-input-native.py` additionally checks actual compositor input, optional actions and Escape/Done focus restoration. Native UI checks must run sequentially so their surfaces cannot cover one another. All these probes use temporary preferences and unavailable device services.

`python3 scripts/check-currency-native.py --capture docs/images` checks Currency with an owned local HTTP server, private settings/cache and an accelerated request watchdog. It covers online and cached cross-rates, dates, actual typing/Swap/Refresh, both themes, offline/invalid responses, cancellation, timeout, stale generations and five reopen cycles. `--live` instead performs a fresh HTTPS conversion against the real Frankfurter provider and removes its temporary cache afterward. These native checks open owned Calculator windows and should run sequentially. Python tests cover bounded responses, validation, private atomic caching and rate rollback; QML tests include live preview, dated history and preserving an Ans-based input across rate updates.

## Pull requests

Use a descriptive commit subject, such as `Fix Bluetooth picker state after disconnect`. Explain the problem, resulting behavior and checks performed; link the relevant issue and include screenshots when useful. State any skipped checks or remaining limitations.

Update the relevant user guide and `CHANGELOG.md` when behavior or dependencies change. Keep unfinished work marked as planned. Exclude local settings, recordings, snapshots, logs and credentials. Report sensitive issues through the [security policy](SECURITY.md).

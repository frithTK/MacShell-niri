# Installation and recovery

[Project overview](../README.md) · [Русский](INSTALL.ru.md)

## Requirements

| Component | Requirements |
| --- | --- |
| Desktop | niri 26.04+; Quickshell with Wayland, PipeWire, Mpris, SystemTray, Notifications, UPower and BackgroundEffect modules |
| Qt | Compatible Qt 6.9+ Declarative, Wayland, SVG and ShaderTools packages. PDF Quick Look also needs the Qt PDF QML module |
| Rust build | Rust and Cargo 1.86+, Gio/GLib and GStreamer development libraries, and the locked dependencies available locally |
| Helpers | GStreamer and `timeout` from coreutils; Python 3.11+ and feature-specific Python modules are needed for legacy profiles, rollback tools and development tests |
| Window previews | PipeWire, niri ScreenCast D-Bus, and GStreamer `pipewiresrc`, `capssetter`, `videoscale`, `videoconvert`, `appsink`, `appsrc`, `pngenc` |
| MacLock | Quickshell PAM and session-lock modules, with an existing PAM service |

Additional programs enable optional features: `curl`, `grim`, `wl-clipboard`, `wtype`, `cliphist`, `wf-recorder`, `ffprobe`, `slurp`, `pw-dump`, `pw-loopback`, `brightnessctl`, `nmcli`, `wlsunset`, `jq`, `inotify-tools`, `mpvpaper` and `ffmpeg`. Recording audio supports Linux recorder builds linked with PipeWire or PulseAudio; PulseAudio builds also need `pipewire-pulse` and `pactl`. Energy modes additionally need power-profiles-daemon or a compatible D-Bus service. See the [detailed dependency and installation guide](INSTALL.ru.md#зависимости) for feature-specific requirements.

Night Shift needs `wlsunset` in the shell's PATH and compositor gamma-control support. It requires no separate autostart, location or schedule setup. The icon toggles it directly; the adjacent arrow opens temperature controls. Battery estimates and available power profiles depend on the hardware and system services.

AirPlay uses optional, separately installed [Doubletake](https://github.com/omarroth/doubletake) (sender) and [UxPlay](https://github.com/FDH2/UxPlay) (receiver), with their GStreamer dependencies. Both are detected on PATH or under `~/.local/share/macshell-niri/runtime/bin`. Receiving is enabled manually and stops with MacShell. Screen Mirroring defaults to 60 FPS and 20% receiver volume on the next connection; the volume option requires the patched Doubletake runtime described in [DOUBLETAKE_RUNTIME.md](DOUBLETAKE_RUNTIME.md). See the [Screen Mirroring guide](CONTROL_CENTER.md#повтор-экрана--airplay).

The installer checks dependencies and does not run a package manager. It builds the Rust niri bridge and color picker, shared boot clock, system statistics, Night Shift, timed modes, native blur, power profiles, Wi-Fi, Bluetooth, window capture and screen recording services, session preflight, Activity, menu bar, widget and locale preferences offline before replacing any installed files. On a new build machine, prepare the locked Cargo dependencies explicitly while online:

```bash
cargo fetch --locked --manifest-path native/niri-bridge/Cargo.toml
cargo fetch --locked --manifest-path native/boot-clock/Cargo.toml
cargo fetch --locked --manifest-path native/system-stats/Cargo.toml
cargo fetch --locked --manifest-path native/night-shift/Cargo.toml
cargo fetch --locked --manifest-path native/timed-modes/Cargo.toml
cargo fetch --locked --manifest-path native/activity-preferences/Cargo.toml
cargo fetch --locked --manifest-path native/bar-preferences/Cargo.toml
cargo fetch --locked --manifest-path native/widget-preferences/Cargo.toml
cargo fetch --locked --manifest-path native/locale-preferences/Cargo.toml
cargo fetch --locked --manifest-path native/native-blur/Cargo.toml
cargo fetch --locked --manifest-path native/session-preflight/Cargo.toml
cargo fetch --locked --manifest-path native/power-profiles/Cargo.toml
cargo fetch --locked --manifest-path native/niri-color/Cargo.toml
cargo fetch --locked --manifest-path native/bluez-session/Cargo.toml
cargo fetch --locked --manifest-path native/network-snapshot/Cargo.toml
cargo fetch --locked --manifest-path native/capture-service/Cargo.toml
cargo fetch --locked --manifest-path native/recording-core/Cargo.toml
cargo fetch --locked --manifest-path native/niri-input/Cargo.toml
cargo fetch --locked --manifest-path native/session-service/Cargo.toml
cargo fetch --locked --manifest-path native/currency-fetch/Cargo.toml
cargo fetch --locked --manifest-path native/widget-fetch/Cargo.toml
cargo fetch --locked --manifest-path native/wallpaper-discovery/Cargo.toml
cargo fetch --locked --manifest-path native/notes-service/Cargo.toml
cargo fetch --locked --manifest-path native/calendar-service/Cargo.toml
cargo fetch --locked --manifest-path native/reminders-service/Cargo.toml
cargo fetch --locked --manifest-path native/clock-core/Cargo.toml
cargo fetch --locked --manifest-path native/screen-mirroring/Cargo.toml
cargo fetch --locked --manifest-path native/airdrop-service/Cargo.toml
cargo fetch --locked --manifest-path native/biometric-probe/Cargo.toml
cargo fetch --locked --manifest-path native/update-service/Cargo.toml
cargo fetch --locked --manifest-path native/desktop-source/Cargo.toml
cargo fetch --locked --manifest-path native/preview/Cargo.toml
```

The Rust build also includes input, session, currency, widget fetch, wallpaper discovery, Notes, Calendar, Reminders, Clock, Screen Mirroring, AirDrop, biometric helpers, the on-demand update service, desktop-source (app origin) and preview (Quick Look). PDF Quick Look needs the Qt PDF QML module; without it the window still opens and reports that PDF preview is unavailable. Screen Mirroring uses Doubletake and UxPlay; AirDrop uses the MacShell Owly backend. Source launchers retain Python fallback for legacy profiles; new Rust-only installations report missing or incompatible helpers as errors. Notes, Calendar and Reminders use bundled SQLite. The Rust Clock service retains its prototype binary name and has been tested with temporary data, nested niri and an isolated PipeWire sink; installed-session acceptance remains outstanding.

The Rust installer builds offline before changing installed files. `--check` verifies Cargo and the Quickshell runtime, not that every component dependency is cached. New installations use Rust-only runtime services; missing or incompatible binaries produce errors rather than invoking Python. A plain install preserves any existing session helpers, which may still require Python; use `--session` from outside MacShell to migrate those helpers. The former `--python-bridge` installer option is retired. Quickshell must be built for the installed Qt version. `MACSHELL_QS_BIN` can select a compatible runtime; installing this port does not replace the system `qs` binary.

The separate login script and its locale and preflight helpers are refreshed with `bash install.sh --session`; a plain installation updates the shell but leaves an existing login script in place.

## Get started

Clone the **niri port**:

```bash
git clone https://github.com/frithTK/MacShell-niri.git
cd MacShell-niri
bash install.sh --check
```

Back up the current desktop configuration:

```bash
umask 077
python3 scripts/desktop_snapshot.py
```

Prepare a separate login profile without switching the running desktop:

```bash
bash install.sh --dry-run --session
bash install.sh --session
~/.local/bin/niri-macshell-session --check
```

For an SDDM login entry, register the installed session files:

```bash
sudo bash ~/.local/share/macshell-niri/session/register-session.sh
```

Log out and select **Niri (MacShell)**. The regular **Niri** session remains available. The `sudo` step is only for registering the login entry; run the installer as your regular user. Commands above show the default XDG paths.

Running `bash install.sh` without flags only installs files. `--activate` switches the current desktop and is a separate installation mode. See the [full installation guide](INSTALL.ru.md#два-варианта-на-экране-входа) before using it.

## Updating an existing installation

Log out of Niri (MacShell), select another session, and run from the checkout:

```bash
git pull --ff-only
bash install.sh --check
bash install.sh
```

This updates the installed shell, locker and launchers, preserving settings and the existing niri profile. Each installation creates a rollback backup. Installation and rollback refuse to run while the MacShell session is active or MacLock is busy or cannot be checked. To install changes to the separate session's systemd units and login launcher, use `bash install.sh --session` instead; it regenerates the separate niri profile from the existing niri configuration. Session registration and `--activate` are not needed for a regular update. Separately installed runtime programs, including `wlsunset`, remain outside the Git checkout.

## Recovery

To return to the previous desktop, log out and select the regular **Niri** session. To remove the extra login entry and undo the latest installation, run from that session:

```bash
sudo bash ~/.local/share/macshell-niri/session/register-session.sh --remove
bash install.sh --rollback
```

Rollback preserves the replaced files and stops if the root niri configuration contains unrelated edits. Details are in the [recovery guide](INSTALL.ru.md#откат).

# Installation and recovery

[Project overview](../README.md) · [Русский](INSTALL.ru.md)

## Requirements

| Component | Requirements |
| --- | --- |
| Desktop | niri 26.04+; Quickshell with Wayland, PipeWire, Mpris, SystemTray, Notifications, UPower and BackgroundEffect modules |
| Qt | Compatible Qt 6.9+ Declarative, Wayland, SVG and ShaderTools packages |
| Helpers | Python 3.11+, PyGObject/Gio, Pillow, gst-python and GStreamer |
| Window previews | PipeWire, niri ScreenCast D-Bus, and GStreamer `pipewiresrc`, `capssetter`, `videoscale`, `videoconvert`, `appsink` |
| MacLock | Quickshell PAM and session-lock modules, with an existing PAM service |

Additional programs enable optional features: `curl`, `grim`, `wl-clipboard`, `wtype`, `cliphist`, `wf-recorder`, `ffprobe`, `slurp`, `pw-dump`, `pw-loopback`, `brightnessctl`, `nmcli`, `wlsunset`, `jq`, `inotify-tools`, `mpvpaper` and `ffmpeg`. Recording audio supports Linux recorder builds linked with PipeWire or PulseAudio; PulseAudio builds also need `pipewire-pulse` and `pactl`. Energy modes additionally need power-profiles-daemon or a compatible D-Bus service. See the [detailed dependency and installation guide](INSTALL.ru.md#зависимости) for feature-specific requirements.

Night Shift needs `wlsunset` in the shell's PATH and compositor gamma-control support. It requires no separate autostart, location or schedule setup. The icon toggles it directly; the adjacent arrow opens temperature controls. Battery estimates and available power profiles depend on the hardware and system services.

AirPlay uses optional, separately installed [Doubletake](https://github.com/omarroth/doubletake) (sender) and [UxPlay](https://github.com/FDH2/UxPlay) (receiver), with their GStreamer dependencies. Both are detected on PATH or under `~/.local/share/macshell-niri/runtime/bin`. Receiving is enabled manually and stops with MacShell. See the [Screen Mirroring guide](CONTROL_CENTER.md#повтор-экрана--airplay).

The installer checks dependencies and does not run a package manager. Quickshell must be built for the installed Qt version. `MACSHELL_QS_BIN` can select a compatible runtime; installing this port does not replace the system `qs` binary.

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

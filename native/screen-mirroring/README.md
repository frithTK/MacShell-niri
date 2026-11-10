# Screen mirroring

JSON-lines helper for AirPlay send (Doubletake) and receive (UxPlay). The
shell talks to it through `ScreenMirroringControl.qml`.

## Layout

`layout` is `mirror` (default) or `extend`. AirPlay always sends a video
stream; Extend needs a real compositor output:

1. `niri msg create-virtual-output` when present (niri PR #3800) creates
   `MacShell-AirPlay`.
2. Otherwise an existing extra physical output is used.
3. Otherwise a disconnected HDMI-A-* / DP-* connector (never eDP) can be
   forced on through DRM debugfs `edid_override` and sysfs `status=on`
   (`DRM_FORCE_ON`) as a 1920×1080 dummy named MacShell. Sysfs `status` is
   what actually probes the connector; debugfs `force` only stores the flag
   and does not call `fill_modes`. Writing debugfs first and then the same
   force via sysfs skips the probe, so the port stays disconnected. Do not
   write `detect` after that: it resets force. HDMI/DP use `on`; `on-digital`
   is DVI-I and is only a fallback. If debugfs is not writable, the helper
   re-execs itself via pkexec (`--drm-dummy`). niri is then asked to turn the
   output on.

State JSON includes `extendAvailable`, `extendOutput`, `extendMethod`
(`virtual` / `output` / `dummy`), `virtualOutputsSupported` and
`extendCapture`. Dummy ownership is released when the session goes idle or
the helper exits. Tests must set `MACSHELL_DRM_SYSFS` to an empty directory
so they do not see the host's HDMI ports.

User-facing behavior: [Screen Mirroring](../../docs/CONTROL_CENTER.md#повтор-экрана--airplay).

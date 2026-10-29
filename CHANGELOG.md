# Changelog

## Unreleased

- Added a persistent, restart-limited MacShell session service and an independently managed MacLock service. Installation and rollback wait for the old shell and refuse changes during an active MacShell session or an active/unknown lock. Isolated niri tests cover the real session lock across shell restart; normal login and PAM acceptance remain pending.

- Prevented Dock window thumbnails from flashing back to their app icons while the next captured frame loads. Added a regression test for refresh, source changes and capture failures.
- Added fingerprint discovery, enrollment, verification and selected-finger deletion in Security & Unlock through system fprintd, with cancellation, cleanup and a warning about hardware storage. The session starts an available graphical PolicyKit agent when needed. MacLock biometric authentication and face unlock remain in development.

- Shared Russian/English desktop language settings across Settings, menu bar, Dock, Spotlight, controls, widgets, utilities and MacLock. Changes retain open inputs, Calculator history/memory and editor drafts; formats, currencies and emoji search use localized data. Stable IDs keep alarm Save/snooze/Stop and graph selection independent of labels.
- User session language and regional formats in Language & Region, with installed-locale validation, atomic private preferences, conflict protection and backups. The MacShell login launcher applies locale before niri and user systemd/D-Bus startup; applications pick it up after a new sign-in.
- Fixed notification clicks accessing a delegate after activation removed it, and cyclic palette bindings in monitoring device selectors. Reviewed the plan for session ownership, locale precedence, biometrics, timer idempotence/DST and imported audio.

- Calculator Currency conversion with daily online reference rates from Frankfurter v2, per-pair observation dates, Refresh and offline caching. Rates load only while Currency is visible, update hourly and retain the last good snapshot on errors. Closing the window cancels requests; amounts stay local.
- Larger Calculator keypad and display: 32px digits, 48px results, 72px main keys, larger scientific/utility labels and roomier default windows in all modes.
- Arrange now covers open applications with the wallpaper and widgets. A compact top strip replaces the controls window, hides during dragging and offers Done/Escape, sizes and optional actions. Leaving Arrange restores desktop layering and focus without moving application windows.
- Built-in Calculator with Basic, Scientific, offline unit conversion, keyboard/clipboard, session memory and 50-entry history. Clock and Calculator share Apps/Spotlight/Dock discovery with Russian search and separate window identities. The full utilities roadmap and T22 timer contract are documented; T23/T24 remain planned.
- Batteries widgets in S/M/L, with automatic or per-card device selection, shared laptop/Bluetooth data, charging status and explicit unknown/disconnected states. Stable device identities avoid duplicates; adding a card never starts Bluetooth discovery.
- Desktop Activity widgets in S/M/L, with per-card metrics, rings/graphs, sample previews and Apply/Cancel. Cards share the menu bar sampler, thresholds and units; details open on the card's display, including when the menu bar is disabled. Unused views release their subscriptions.

## 1.0.0 — 2026-10-25

The first full release of MacShell-niri.

- A macOS-inspired desktop for niri: menu bar, Dock, Spotlight, notifications, tray, wallpapers, app switching and MacLock.
- Liquid Glass with light/dark themes, adjustable refraction and blur, and live compositor blur when window geometry is incomplete.
- Weather, Calendar, Clock and Player widgets with S/M/L sizes, per-card appearance, duplication, display placement and removal Undo. Shared subscriptions pause unused work.
- A customizable menu bar and Activity icons with CPU, memory, network and disk graphs.
- Control Center with Wi-Fi, Bluetooth, audio devices and application volume up to 150%, battery and power profiles, Focus, Keep Awake, Night Shift and screen recording.
- Optional AirPlay sending/receiving through Doubletake/UxPlay and AirDrop through supported Owly Shared setups. Modes that disconnect Wi-Fi are blocked.
- Installation with backups and rollback, desktop snapshots and a separate Niri (MacShell) login session.
- English/Russian guides, 24 interface screenshots, a recorded tour and automated Python/QML/native protocol checks.

[Release notes](docs/releases/v1.0.0.md) · [Installation](docs/INSTALL.md) · [Установка](docs/INSTALL.ru.md) · [Performance](docs/PERFORMANCE.md)

The Git history starts with this release snapshot. Original MacShell attribution and MIT notices are preserved; see [source history](docs/HISTORY.md).

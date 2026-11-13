# Changelog

## Unreleased

- MacLock unlocks with any enrolled fingerprint through fprintd, in parallel with the password field. The field reads “Fingerprint or password”; an unrecognized finger shakes it without clearing typed characters. After 5 unrecognized scans only the password unlocks that lock. A busy or disconnected reader (for example after sleep) is retried with backoff. System PAM files are not changed; login after a restart still uses the password. Settings → Security & Unlock has a switch for it and no longer calls fingerprint unlock “in development”.
- Settings → Storage shows volumes immediately, collapses same-disk btrfs subvolumes, and splits used space into Apps, Photos, Videos, Documents, Downloads, Music, Desktop, Trash, Cache, Other and System. Trash is measured across home and volume trashes before the folder walk, so the visit limit cannot hide it, and its items are listed. Cache is walked last.
- “Show in Folder” opens a graphical file manager (FileManager1, then Dolphin/Nautilus/Nemo/Thunar/PCManFM/Caja) instead of `xdg-open`, which could open a terminal file manager.
- Settings → About lists the computer model, chip, memory, graphics, displays, startup disk, OS, kernel, niri and MacShell versions read from the running system, instead of a fixed version string and joke cards.
- The Trash window no longer shows an empty list when the helper returns its items as an array-like value.

## 1.2.5

- Liquid Glass looks are Clear / Standard / Vibrant / Tinted / Frosted. Named looks keep a see-through centre and a refracting rim; Tinted and Frosted thicken the film instead of trading refraction for frosting. Changing the look while Control Center is closed no longer leaves its shader off.
- Glass samples live window pixels, not only the wallpaper. The niri profile sets `xray false` on MacShell layers. The niri bridge reconstructs tiled window geometry from the scrolling layout when niri omits screen coordinates, so Control Center and Spotlight can refract windows.
- Convert is a file-manager submenu (Nautilus, Nemo, Caja, Dolphin, Thunar), not a Dock or Apps window. The helper still writes PNG, JPEG, PDF or a 90° rotate beside the original.
- Screen Mirroring always mirrors. The Control Center Extend picker is gone; connecting releases a leftover HDMI dummy force so a previous Extend session cannot leave the port on. Receive still uses UxPlay; 1.73.7 needs the PIN proof-length patch in `docs/UXPLAY_RUNTIME.md`.
- Batteries auto/small keeps advertised AirPods/Beats charge beside the laptop, not only while BlueZ reports connected.
- Spotlight ranking and file-search process live in `SpotlightSearch.qml` / `SpotlightRank.js`; the overlay stays in MacBar.
- Stickies paper color is one of six named papers and is stored in the window layout, not in the note body.
- Calendar expands local daily/weekly/monthly repeats on read and sends `notify-send` alerts (all-day at 09:00 in the event zone). CalDAV/ICS stay out of scope.
- Notes store `format`/`excerpt`, sanitize a small HTML subset, and keep file attachments beside the database. Stickies still edit plain text.
- Settings → Security no longer promises Face unlock or PAM/MacLock changes; fingerprint templates stay on the reader.
- Hyprland desktop sheets, genie minimize and foreign window decorations are documented as nongoals for the niri port.
- Source launchers and the generated `macshell-niri` session launcher no longer fall back to Python; missing or incompatible Rust binaries fail. Python service modules remain for comparison tests.

## 1.2.4

- Convert turns local PNG/JPEG/GIF/BMP into PNG, JPEG or a one-page PDF, or rotates 90°, and can render the first PDF page when `pdftoppm` is installed. New files are written beside the original; name clashes get a numeric suffix; batches can succeed in part. Wayland has no global Shift+drag — open Convert from Spotlight, Apps, IPC, or drop files onto its window.
- Settings → Storage lists mounted volumes (total/used/free, bind mounts, unavailable disks) and can scan user folders, Trash and app data whose directory matches a desktop id. Folder totals are apparent sizes, not a full disk map; hard links count once, other mounts are skipped, and the walk is cancellable. Cleanup stays in Trash / the app; this page does not delete files.
- Settings → Battery shows current/last-full energy, discharge rate when UPower reports a real draw, extra present batteries, and an explicit note that per-app energy use is not available. Remaining-time estimates longer than 36 hours or at ~0 W are treated as unknown instead of “167 days empty”.
- Spotlight finds Settings panes by localized names and offers per-result actions. Files get Show in Folder, Copy Path and Quick Look; apps share the Dock menu (pin, reveal, info). Filename search no longer needs a `file`/`find` prefix: from two characters it asks localsearch, then `fd`, then `find`, keeps three result slots beside apps, and does not scan for calculator or unit queries. `file`/`find` still shows only files. The Files button opens the home folder through `xdg-open`, not a hardcoded Dolphin. The Apps shortcut, Help menu niri/Quickshell entries, and window Floating/Zoom labels are translated.
- Batteries reads AirPods/Beats charge from the AACP control channel while the headphones are connected to this computer (1% steps for L/R/case). The helper drains handshake replies and sends a battery request so the first status frame is not missed. Apple Bluetooth advertisements still fill in charge while the card is visible and the buds are in the case or owned by another host. `org.bluez.Battery1` still wins when BlueZ exposes it. Control Center pairing search is unchanged.
- The Appearance **Glass look** control is a four-way segmented picker (Clear / Standard / Vibrant / Frosted). Named looks still apply as a set, so a Settings flick can no longer swallow the drag and leave the previous preset.
- Screen Mirroring can **Extend** the desktop onto AirPlay as a second output: a niri virtual output when the compositor supports it, an existing extra display, or a password-authorized HDMI/DisplayPort DRM dummy. Mirror remains the default. The dummy writes EDID then sysfs `status=on` so the kernel actually probes the port (debugfs `force` alone does not). It no longer writes debugfs first and then the same force via sysfs, which left HDMI disconnected after the password was accepted. `detect` is still not written afterwards. If the GPU still leaves the port disconnected, the error mentions an HDMI dummy plug or niri virtual outputs.
- A Rust helper resolves each app's desktop file and origin (pacman, Flatpak user/system, local, builtin). Package remove/reinstall/update needs a second confirmation, re-checks the source, and runs through pkexec. Pacman update is a full system `-Syu`. Tests use fixtures and do not change host packages.
- Quick Look previews local images, PDF and plain text from Spotlight (action menu, Ctrl+Y, or `spotlight preview`). Oversized, missing and unsupported files show an explicit message. A selected local file can be dragged out with `text/uri-list`. Space in Nautilus still uses that file manager's own preview.
- Dock Trash lists FreeDesktop trash (`$XDG_DATA_HOME/Trash` and volume `.Trash-$uid` / `.Trash/$uid`). Restore, Quick Look and Empty Trash stay in that window; emptying only deletes discovered `files/` and `info/` directories, not an arbitrary path.
- The menu bar uses the focused window's D-Bus menus (`com.canonical.dbusmenu` / `org.gtk.Menus`) when the exporter's pid matches the niri window. Apps that do not export a menu keep the shell stubs; niri has no kde-appmenu and no X11 registrar.

## 1.2.3

- Refined Liquid Glass rim and inner shading on the menu bar, Dock and widgets. Dock can load a dedicated glass shader and falls back to the shared one if that shader fails.
- Control Center tiles use the flatter glass treatment. Opening Wi-Fi or Bluetooth from Control Center keeps the list inside that panel, with Back and Escape; the matching menu-bar icons still open separate popovers.
- Dock hover labels and context menus use a Tahoe-style glass bubble with a tail. Launch bounce eases out instead of cutting off; Trash and app menus follow light and dark themes.
- Shared `ControlSwitch`, `ControlSlider`, `LevelSlider` and `SegmentedControl` match the newer capsule shapes; a glass lens is used while dragging where the shader loads.
- Calendar desktop cards place the month grid on integer cells and draw an even “today” circle in the same box as the date.
- Desktop widget catalog adds Notes and Reminders cards on the existing Rust stores (not ExtraWidgets markdown files) and an Image card for a local file path only. Network image URLs are rejected. Stocks, Photos and ExtraWidgets Alarms are not included.
- Isolated nested-niri click checks cover Control Center navigation and Dock menus, bounce, auto-hide and glass fallback. Offscreen QML tests cover the new widget cards, calendar grid, segmented control and Dock glass panel.
- Appearance and Menu Bar replace the raw glass sliders with a Clear / Standard / Vibrant / Frosted look. Named looks keep blur below the half-resolution threshold. Blur, refraction and frosting stay under Advanced.

## 1.2.2

- Fixed CI dependency preparation for offline Rust builds and installation tests.
- Updated the installation requirement to Rust/Cargo 1.86 or newer.

## 1.2.1

- Removed the previously bundled third-party sound recordings and default alarm/timer audio. Users can import their own sounds.
- Migrated new shell and session installations to Rust-only services and installer; legacy profiles retain their existing compatibility paths.
- Added Calendar screenshots and updated installation documentation.

## 1.2.0
- Added a standalone Calendar app with local event storage and integration with the Dock and app search.
- Moved system services including Wi-Fi, Bluetooth, window capture, screen recording and desktop settings to Rust, with Python fallback during the transition.
- Added isolated integration coverage for installation and rollback, system buses, and screen capture and recording with virtual sources. Hardware and normal-session acceptance remain outstanding.
- Updated installation requirements for the Rust build and native capture dependencies.
- Added a Rust-first on-demand update service with stable release checks, tagged checkout verification, package checks and explicit preparation without automatic MacShell installation; Python remains the fallback.

## 1.1.2

- Simplified Notes and Reminders controls with accessible add and restore icons; deleted reminders are restored from Recently Deleted.
- Stickies open at a compact size and restore open windows, their sizes and positions after the shell restarts.

- Fixed the Dock Trash icon when the active system icon theme cannot supply it; bundled icons show empty and full states.
- MacLock now shows the active keyboard layout on every display and marks it unknown if the compositor connection is lost.
- Added Stickies: multiple floating note windows with autosave, shared Notes storage and conflict-safe copies.
- Refined the built-in Notes, Reminders, Calculator and Clock interfaces with consistent window controls, updated sidebars, rounded controls and light/dark materials.
- Replaced the Notes and Reminders edit and delete buttons with labeled, keyboard-accessible pencil and trash icons.
- Fixed default World Clock cities loading without their time-zone offsets on the first managed-service snapshot.

## 1.1.1

- Fixed Spotlight mouse selection when window information changes during a search; pointer highlighting now follows the mouse immediately.
- Added Settings → Updates to check stable MacShell releases and prepare an update, plus optional pacman update checks on supported systems. Installation remains a separate, user-confirmed step outside the active MacShell session.

## 1.1.0

- Добавлены 65 звуков из сторонней подборки macOS; прежние синтезированные варианты по умолчанию скрыты. Личные импортированные файлы в поставку не входят. Источник и неподтверждённые права на записи указаны в THIRD_PARTY_NOTICES.md.
- В библиотеке Clock можно скрыть встроенные звуки и затем вернуть их, не нарушая работу ранее настроенных будильников.
- Добавлен локальный срез Notes: текстовые заметки, поиск, автосохранение, Undo и восстановление удалённых заметок после повторного открытия. Транзакционная база хранится отдельно от настроек; при конфликте несохранённый текст можно сохранить копией.
- Notes можно открыть отдельным процессом из текущего checkout без обновления установленной оболочки; повтор команд после аварии службы до и после записи проверен с реальной базой.
- Добавлены Reminders: локальные списки и задачи, поиск, отметка выполнения, редактирование и восстановление удалённых элементов после перезапуска. Поддерживаются сроки и системные уведомления при закрытом окне с сохранёнными состояниями доставки, а также ежедневный, еженедельный и ежемесячный повтор после выполнения.

### More changes

- Added a desktop Timer widget in three sizes with shared Clock controls, per-card duration presets and confirmation before replacing an active timer.
- Clock now uses a shared service for timers, alarms, snooze and the stopwatch. Timers include suspend, survive shell restarts and offer explicit recovery after reboot. Added built-in alert sounds and preserved legacy data during migration.
- Clock retries a failed custom alert sound with its built-in sound and reports the fallback in the app.
- Added Clock's sound library with 40 generated sounds, local audio import, search and preview, and sound selection for alarms and timers.
- Added sound-library favorites, category filters and confirmed deletion that protects sounds used by alarms, active timers and pending alerts.
- Added cancellable sound imports, renaming and duration display, and per-alert volume, fade, fragment and repeat settings; recent timer presets retain their settings.
- Fixed Clock and MacLock to use the same settings path when `XDG_CONFIG_HOME` is set. Fixed argument forwarding to JSON service processes.
- MacLock reads versioned Clock timers and stopwatches using a shared boot-time source, with explicit recovery and unavailable states.

- Added a persistent, restart-limited MacShell session service and an independently managed MacLock service. Installation and rollback wait for the old shell and refuse changes during an active MacShell session or an active/unknown lock. Isolated niri tests cover the real session lock across shell restart; normal login and PAM acceptance remain pending.

- Prevented Dock window thumbnails from flashing back to their app icons while the next captured frame loads. Added a regression test for refresh, source changes and capture failures.
- Added fingerprint discovery, enrollment, verification and selected-finger deletion in Security & Unlock through system fprintd, with cancellation, cleanup and a warning about hardware storage. The session starts an available graphical PolicyKit agent when needed. MacLock biometric authentication and face unlock remain in development.

- Shared Russian/English desktop language settings across Settings, menu bar, Dock, Spotlight, controls, widgets, utilities and MacLock. Changes retain open inputs, Calculator history/memory and editor drafts; formats, currencies and emoji search use localized data. Stable IDs keep alarm Save/snooze/Stop and graph selection independent of labels.
- User session language and regional formats in Language & Region, with installed-locale validation, atomic private preferences, conflict protection and backups. The MacShell login launcher applies locale before niri and user systemd/D-Bus startup; applications pick it up after a new sign-in.
- Fixed notification clicks accessing a delegate after activation removed it, and cyclic palette bindings in monitoring device selectors.

- Calculator Currency conversion with daily online reference rates from Frankfurter v2, per-pair observation dates, Refresh and offline caching. Rates load only while Currency is visible, update hourly and retain the last good snapshot on errors. Closing the window cancels requests; amounts stay local.
- Larger Calculator keypad and display: 32px digits, 48px results, 72px main keys, larger scientific/utility labels and roomier default windows in all modes.
- Arrange now covers open applications with the wallpaper and widgets. A compact top strip replaces the controls window, hides during dragging and offers Done/Escape, sizes and optional actions. Leaving Arrange restores desktop layering and focus without moving application windows.
- Built-in Calculator with Basic, Scientific, offline unit conversion, keyboard/clipboard, session memory and 50-entry history. Clock and Calculator share Apps/Spotlight/Dock discovery with Russian search and separate window identities. The timer contract is documented.
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

[Release notes](docs/releases/v1.0.0.md) · [Installation](docs/INSTALL.md) · [Установка](docs/INSTALL.ru.md)

The Git history starts with this release snapshot. Original MacShell attribution and MIT notices are preserved; see [source history](docs/HISTORY.md).

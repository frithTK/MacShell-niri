# Changelog

## 1.1.2

- Fixed the Dock Trash icon when the active system icon theme cannot supply it; bundled icons show empty and full states.
- MacLock now shows the active keyboard layout on every display and marks it unknown if the compositor connection is lost.
- Added Stickies: multiple floating note windows with autosave, shared Notes storage and conflict-safe copies.
- Stickies windows are not restored after restarting the shell; their initial size may vary with niri configuration.
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

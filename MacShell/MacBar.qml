// macOS-style panel for niri. Compositor operations live in Niri.qml.
import QtQuick
import "Locale" as Language
import "GlassTheme.js" as GlassTheme
import "SettingsMigrations.js" as SettingsMigrations
import "BarLayout.js" as BarLayout
import "SettingsSearch.js" as SettingsSearch
import "AppMenu.js" as AppMenu
import "QuickLook.js" as QuickLook
import QtQuick.Controls as Controls
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.SystemTray
import Quickshell.Services.UPower
import Quickshell.Services.Pipewire
import Quickshell.Services.Mpris
import Quickshell.Services.Notifications
import "EmojiData.js" as EmojiData
import "Utilities.js" as Utilities

Scope {
    id: root

    // shared helpers from shell.qml (window geometry poller, wallpaper lookup)
    property var hub: null
    property int desktopSourceTick: 0
    Connections {
        target: hub && hub.desktopSource ? hub.desktopSource : null
        function onResolved(appId, source) { root.desktopSourceTick++; }
        function onApplied(ok, error, op, appId) { root.desktopSourceTick++; }
    }
    // Pause window captures while this shell records the screen.
    readonly property bool captureQuiet: hub ? hub.captureQuiet : recording || mirroring.quiet
    // windows opening / closing: the glass's live captures pause (it keeps its last frame; the source stays attached) - see shell.qml: hub.glassHold
    readonly property bool captureHeld: hub ? hub.glassHold : false

    function captureGlass(item) {
        var window = item.QsWindow.window;
        return !!(hub && window && window.screen && hub.glassReady(window.screen.name));
    }

    // ───────────── CONFIG (all persisted to settings.json) ─────────────
    property bool barEnabled: true           // the menu bar strip itself
    // every part of the shell can be switched off on its own (the installer's feature picker writes these too)
    property bool spotlightEnabled: true     // Spotlight (the magnifier / its keybind)
    property bool ccEnabled: true            // Control Center
    property string ccStyle: "tiles"         // tiles = every control its own glass | macos = one frosted panel behind them
    property bool notificationsEnabled: true // banners + Notification Center (off = no D-Bus daemon at all, so mako/dunst can take over)
    property bool clockAppEnabled: true      // the Clock app (alarms and timers still ring while it is on)
    readonly property bool barLayerNeeded: barEnabled || spotlightEnabled || ccEnabled || notificationsEnabled || keepAwake
        || activeControl === "stats" || !!hub && !!hub.widgets && hub.widgets.widgetsEnabled
            && hub.widgets.renderedRows.some(row => row.wtype === "activity")
    property bool darkMode: true
    property color accent: "#0A84FF"
    // "Inter" renders with the single variable file: the static Inter.ttc got mapped once per face (~25×13 MB of RSS)
    property string fontFamily: "Inter Variable"
    onFontFamilyChanged: if (fontFamily === "Inter" || fontFamily === "Inter Display") fontFamily = "Inter Variable"
    property int barHeight: 28
    property string barLogoMode: "arch"       // "arch", "apple", or "custom"
    property string barCustomLogoPath: ""     // absolute path, ~/path, or file URL for the custom menu-bar logo
    // The bar-size slider scales its widget groups while the left/right groups stay pinned to their corners.
    readonly property real barWidgetScale: Math.max(0.8, Math.min(1.55, barHeight / 28))
    readonly property real barPopupScale: Math.max(0.9, Math.min(1.25, 1 + (barHeight - 28) / 88))
    property real glassOpacity: 0.42
    property string barStyle: "liquid"        // "liquid" = Apple Liquid Glass popovers, "blur" = flat translucent
    property real glassRim: 0.45
    property real glassGrain: 0.015
    property real glassLiquid: 1.0
    property real glassBlur: 5
    property int kbRepeatRate: 35
    property int kbRepeatDelay: 250
    property real mouseSens: 0
    property bool mouseNatural: false
    property bool tpNatural: true
    property bool tpTap: true
    property bool tpDwt: true
    property real tpScroll: 0.7
    readonly property string inputSig: [kbRepeatRate, kbRepeatDelay, mouseSens, mouseNatural, tpNatural, tpTap, tpDwt, tpScroll].join("|")
    onInputSigChanged: if (settingsReady) inputApplyT.restart()
    Timer { id: inputApplyT; interval: 150; onTriggered: root.applyInput() }
    property string inputApplyError: ""
    property bool inputApplyQueued: false
    property string inputRecoveryStatus: "unknown"
    property string inputRecoveryMessage: ""
    property bool inputRecoveryBusy: false
    function applyInput() {
        // A dedicated optional include keeps the user's input configuration intact.
        var request = [Qt.resolvedUrl("niri-input-service.sh").toString().replace(/^file:\/\//, ""), "input", JSON.stringify({
            repeatRate: kbRepeatRate, repeatDelay: kbRepeatDelay, mouseSens: mouseSens,
            mouseNatural: mouseNatural, tpNatural: tpNatural, tpTap: tpTap, tpDwt: tpDwt, tpScroll: tpScroll
        })];
        if (inputApplyProc.running) {
            inputApplyQueued = true;
            return;
        }
        inputApplyQueued = false;
        inputApplyProc.command = request;
        inputApplyProc.running = true;
    }
    Process {
        id: inputApplyProc
        stderr: StdioCollector { id: inputApplyStderr }
        onExited: (code, status) => {
            var detail = (inputApplyStderr.text || "").trim().replace(/\s+/g, " ");
            if (code === 0) {
                root.inputApplyError = "";
            } else {
                if (detail.length > 240) detail = detail.substring(0, 237) + "...";
                root.inputApplyError = detail || "Could not apply input preferences.";
                Quickshell.execDetached(["notify-send", "-a", "macbar", "Input preferences", root.inputApplyError]);
            }
            if (root.inputApplyQueued) {
                root.inputApplyQueued = false;
                inputApplyT.restart();
            }
        }
    }
    function diagnoseInput() {
        if (inputRecoveryProc.running) return;
        inputRecoveryBusy = true;
        inputRecoveryProc.command = [Qt.resolvedUrl("niri-input-service.sh").toString().replace(/^file:\/\//, ""), "diagnose"];
        inputRecoveryProc.running = true;
    }
    function cleanupInput() {
        if (inputRecoveryProc.running || inputRecoveryStatus !== "cleanup_safe") return;
        inputRecoveryBusy = true;
        inputRecoveryProc.command = [Qt.resolvedUrl("niri-input-service.sh").toString().replace(/^file:\/\//, ""), "resolve-cleanup"];
        inputRecoveryProc.running = true;
    }
    Process {
        id: inputRecoveryProc
        stdout: StdioCollector { id: inputRecoveryStdout }
        stderr: StdioCollector { id: inputRecoveryStderr }
        onExited: (code, status) => {
            root.inputRecoveryBusy = false;
            var text = (inputRecoveryStdout.text || "").trim(), result = null;
            try { result = JSON.parse(text); } catch (e) {}
            if (code === 0 && result) {
                root.inputRecoveryStatus = result.status || "conflict";
                root.inputRecoveryMessage = result.error || "";
            } else {
                root.inputRecoveryStatus = "unsupported";
                root.inputRecoveryMessage = (inputRecoveryStdout.text || inputRecoveryStderr.text || "Recovery diagnostics unavailable.").trim();
            }
        }
    }
    property int toneEpoch: 0
    function invalidateTone() { toneEpoch++; bgTone = 0; }
    // measure brightness behind a screen rect (logical coords): one tiny grim grab, mean luminance
    function measureTone(sx, sy, sw, sh) {
        if (!autoContrast || toneProc.running) return;
        // perceived brightness of the sRGB means (a "gray" conversion in ImageMagick is linear-light and reads mid-tones far too dark)
        toneProc.command = ["sh", "-c", "grim -s 0.08 -g \"$1,$2 $3x$4\" - 2>/dev/null | magick - -format \"$5 %[fx:0.299*mean.r+0.587*mean.g+0.114*mean.b]\" info: 2>/dev/null",
                            "sh", String(Math.round(sx)), String(Math.round(sy)), String(Math.max(8, Math.round(sw))), String(Math.max(8, Math.round(sh))), String(toneEpoch)];
        toneProc.running = true;
    }
    function acceptTone(text) {
        var parts = text.trim().split(/\s+/), epoch = Number(parts[0]), v = Number(parts[1]);
        if (parts.length !== 2 || epoch !== toneEpoch || !autoContrast || !isFinite(v) || v < 0 || v > 1) return false;
        var L = Math.pow(v, 2.2);
        if (darkMode) {
            var tint = Math.min(.6, glassOpacity * .55 + .05);
            var effD = L * (1 - tint) + .004 * tint;
            bgTone = (1.05 / (effD + .05)) < 3 ? 1 : 0;
        } else {
            // Match the actual light material rather than the old weak tint.
            var light = GlassTheme.lightTint(glassOpacity);
            var surface = Math.pow(v * (1 - light) + light, 2.2);
            bgTone = ((surface + .05) / .062) < 3 ? -1 : 0;
        }
        return true;
    }
    Process {
        id: toneProc
        stdout: StdioCollector { onStreamFinished: root.acceptTone(text) }
    }
    property bool lockArtBackground: true     // lock screen: blurred album art as the background while the cover is enlarged
    // lock screen clock (Settings → Lock Screen → Clock); MacLock reads these when it starts
    property string lockClockStyle: "glass"   // preset last picked: glass | classic | serif | liquid | thin | custom
    property string lockClockFont: "condensed"   // condensed | rounded | serif | inter
    property int lockClockWeight: 680
    property string lockClockMaterial: "glass"   // solid (Apple's vibrancy) | glass (Liquid Glass)
    property real lockClockIntensity: 0.6        // solid: how bright / opaque; glass: clear (0) … frosted (1)
    property string lockClockTint: "#FFFFFF"
    property bool lockClockTall: true
    property string lockClockDate: "long"        // long ("Friday, October 16") | short ("Fri Oct 16")
    readonly property var lockClockPresets: ({
        glass:   { f: "condensed", w: 680, m: "glass", i: 0.6,  t: true,  d: "long" },
        classic: { f: "rounded",   w: 600, m: "solid", i: 0.8,  t: false, d: "long" },
        serif:   { f: "serif",     w: 560, m: "solid", i: 0.85, t: false, d: "short" },
        liquid:  { f: "condensed", w: 560, m: "glass", i: 0.12, t: true,  d: "short" },
        thin:    { f: "rounded",   w: 200, m: "solid", i: 0.6,  t: false, d: "short" }
    })
    // settings saved before Solid / Glass existed: move them over (presets keep their name, the rest map across)
    onLockClockMaterialChanged: Qt.callLater(function () {
        if (lockClockMaterial !== "frosted" && lockClockMaterial !== "liquid") return;
        if (lockClockPresets[lockClockStyle]) { applyLockClockPreset(lockClockStyle); return; }
        lockClockIntensity = lockClockMaterial === "liquid" ? 0.12 : 0.6;
        lockClockMaterial = "glass";
    })
    function applyLockClockPreset(name) {
        var p = lockClockPresets[name]; if (!p) return;
        lockClockFont = p.f; lockClockWeight = p.w; lockClockMaterial = p.m; lockClockIntensity = p.i; lockClockTall = p.t; lockClockDate = p.d;
        lockClockStyle = name;
    }
    property bool uiSounds: true              // Apple-style UI sounds (volume pop, notification, screenshot, charger, lock)
    property bool gamingMode: false           // Game Mode switched on by hand
    property bool gamingAuto: true            // Game Mode turns itself on while a game is fullscreen
    property bool gamingAutoActive: false
    readonly property bool gaming: gamingMode || gamingAutoActive
    property bool ccMigGame: false            // one-time: add the Game Mode tile to an existing Control Center layout
    property bool barGlass: true              // the bar strip itself is Liquid Glass (needs barStyle "liquid")
    property real barBgOpacity: 0.10          // fill of the separate "macbarbg" layer (0 = layer hidden). Must stay above the layerrule's ignore_alpha (0.05) for niri to blur it
    property bool glassRealtime: false        // retain nearby Dock capture sources between openings
    property bool glassDebug: false
    property string wallpaperPath: ""
    property bool use24h: true
    property bool showDate: true
    property bool showSeconds: false
    property bool showBatteryPercent: true
    property bool showTray: true
    property bool showSearch: true
    property bool weekStartsMonday: false
    property string terminal: "kitty"
    property string launcher: ""              // "" = built-in Spotlight; set a command (rofi, fuzzel, ...) to use an external launcher instead
    property string filesCmd: "xdg-open \"$HOME\""
    property string clipboardCmd: "cliphist list | (fuzzel --dmenu || wofi --dmenu || rofi -dmenu) | cliphist decode | wl-copy"
    property var appUsage: ({})               // launch counts, feeds the "Suggestions" row in Spotlight
    property bool clipHistory: true           // keep a clipboard history for Spotlight → Clipboard (needs wl-clipboard + cliphist)
    property bool clipAutoPaste: true         // after picking a clipboard entry / emoji, paste it into the focused app
    property var emojiRecent: []              // recently used emoji, newest first
    property string screenshotDir: ""         // where screenshots are saved ("" = ~/Pictures/Screenshots)
    property bool screenshotSave: true        // save the PNG to screenshotDir
    property bool screenshotClipboard: true   // also copy it to the clipboard
    property bool screenshotNotify: true      // "Screenshot saved" notification
    property int spotRequest: 0
    property string spotWant: "home"          // which Spotlight panel the next request opens: home | clip | emoji | apps
    property int nightTemp: 4000
    onNightTempChanged: if (nightTemp < 2500 || nightTemp > 6000) nightTemp = Math.max(2500, Math.min(6000, nightTemp))
    // Control Center: ids of the enabled controls, in order (edit with Control Center → Edit Controls)
    property var ccControls: ["wifi", "nowplaying", "bluetooth", "airplane", "focus", "record", "mirroring", "airdrop", "nightshift", "keepawake", "display", "sound"]
    property bool ccMirroringMigrated: false
    property bool ccAirDropMigrated: false
    property string airplayReceiverName: "MacShell"
    property int airplayFps: 60
    property int airplayVolumePercent: 20
    property string airdropReceiverName: "MacShell"
    property bool ccMigRec: false              // one-time: add the Screen Recording tile to an existing Control Center layout
    readonly property bool recording: recordingControl.recording
    readonly property int recSecs: recordingControl.seconds
    property var otherConnections: []
    property string keyboardLayout: "EN"      // two-letter label shown in the bar
    property var kbLayouts: []                // configured layouts of the main keyboard: [{ code, name }]
    property int kbIndex: 0                   // index of the active one
    property string kbMain: ""                // name of the main keyboard (niri)
    property string recordFile: ""
    property string fileQuery: ""
    property string fileSearchFor: ""
    property bool fileSearchPending: false
    property var fileHits: []

    readonly property var settingKeys: ["barEnabled", "darkMode", "accent", "fontFamily", "barHeight", "glassOpacity",
        "barStyle", "barGlass", "glassRim", "glassGrain", "glassLiquid", "glassBlur", "barBgOpacity", "glassRealtime", "glassDebug", "wallpaperPath", "use24h", "showDate",
        "showSeconds", "showBatteryPercent", "showTray", "showSearch",
        "spotlightEnabled", "ccEnabled", "notificationsEnabled", "clockAppEnabled", "ccStyle", "barLogoMode", "barCustomLogoPath", "barWidgets", "weekStartsMonday", "terminal", "launcher",
        "filesCmd", "clipboardCmd", "appUsage", "clipHistory", "clipAutoPaste", "emojiRecent", "screenshotDir", "screenshotSave", "screenshotClipboard", "screenshotNotify", "nightTemp", "ccControls", "ccMigRec", "wallpaperDir", "wallpaperFavs", "wallpaperCmd", "wallpaperVideo", "uiSounds", "gamingMode", "gamingAuto", "ccMigGame", "lockArtBackground",
        "lockClockStyle", "switcherStyle", "lockClockFont", "lockClockWeight", "lockClockMaterial", "lockClockIntensity", "lockClockTint", "lockClockTall", "lockClockDate", "autoContrast", "wallpaperAppearance", "wpPairLight", "wpPairDark",
        "notifDnd", "dnd", "nightOn", "keepAwake",
        "kbRepeatRate", "kbRepeatDelay", "mouseSens", "mouseNatural", "tpNatural", "tpTap", "tpDwt", "tpScroll", "statsMigrated", "statsMetrics", "statsInterval", "statsInterface", "statsDevice", "statsMemoryPercent", "modesMigrated", "modeState", "nightDesired", "recordOutput", "recordMicrophone", "recordSink", "recordAudio", "ccMirroringMigrated", "ccAirDropMigrated", "airplayReceiverName", "airplayFps", "airplayVolumePercent", "airdropReceiverName"]
    // Optional bar widgets; tray and Spotlight use their existing showTray/showSearch settings.
    property var barWidgets: ["monitoring", "appleMenu", "appMenus", "workspaces", "volume", "keyboard", "notifications", "wifi", "bluetooth", "privacy", "controlCenter", "clock"]
    property bool statsMigrated: false
    property var statsMetrics: ["cpu", "memory", "network", "disk"]
    property int statsInterval: 1
    onStatsIntervalChanged: if ([1, 2, 5].indexOf(statsInterval) < 0) statsInterval = 1
    property string statsInterface: ""
    property string statsDevice: ""
    property bool statsMemoryPercent: false
    property alias stats: statsControl
    property string popupOwner: ""
    property string activeControl: ""
    property string interactionScreen: ""
    property int statsConsumers: 0
    property bool statsPreferencesOpen: false
    property alias activityPreferences: activityPreferencesControl
    ActivityPreferences { id: activityPreferencesControl; enabled: root.settingsReady }
    signal controlRequested(string name)
    signal monitoringRequested(string outputName)
    onControlRequested: name => { if (name === "airdrop") Qt.callLater(() => airDropWindow.open()); }
    function showMonitoring(outputName) { if (outputName) monitoringRequested(outputName); else controlRequested("stats"); }
    SystemStats {
        id: statsControl
        enabled: root.settingsReady && (root.statsConsumers > 0 || root.activeControl === "stats" || root.statsPreferencesOpen
            || !!root.hub && !!root.hub.widgets && root.hub.widgets.subscriptions.counts.stats > 0)
        interval: root.statsInterval
        interfaceName: root.statsInterface
        device: root.statsDevice
    }
    property alias barLayout: barLayoutControl
    property var barFrames: ({})
    property var barInks: ({})
    BarPreferences {
        id: barLayoutControl; enabled: root.settingsReady
        legacy: ({barWidgets: root.barWidgets, showTray: root.showTray, showSearch: root.showSearch, ccEnabled: root.ccEnabled})
        outputs: Niri.monitors.values
        widgetScale: root.barWidgetScale
    }
    function barWidgetEnabled(id) { return barLayoutControl.ready ? barLayoutControl.commonEnabled(id) : barWidgets.indexOf(id) >= 0; }
    function resolvedBarLogoUrl() {
        var p = String(barCustomLogoPath || "").trim();
        if (p === "") return "";
        if (p.indexOf("://") >= 0) return p;
        var home = Quickshell.env("HOME") || "";
        if (p === "~") p = home;
        else if (p.indexOf("~/") === 0) p = home + p.substring(1);
        else if (p.charAt(0) !== "/") p = home + "/" + p;
        return "file://" + encodeURI(p).replace(/#/g, "%23").replace(/\?/g, "%3F");
    }
    readonly property string barCustomLogoUrl: resolvedBarLogoUrl()
    function setBarWidget(id, enabled) {
        if (barLayoutControl.ready) { barLayoutControl.setEnabled(id, enabled); return; }
        var next = [];
        for (var i = 0; i < barWidgets.length; i++) if (barWidgets[i] !== id) next.push(barWidgets[i]);
        if (enabled) next.push(id);
        barWidgets = next;
    }
    readonly property var accentChoices: [
        { name: Language.I18n.text("ui.t_ec7d56a01607"), c: "#0a84ff" }, { name: Language.I18n.text("ui.t_7d465fb9b931"), c: "#bf5af2" }, { name: Language.I18n.text("ui.t_bd38ed773240"), c: "#ff375f" },
        { name: Language.I18n.text("ui.t_ba19e9c3d5f4"), c: "#ff453a" }, { name: Language.I18n.text("ui.t_78e7771b8b46"), c: "#ff9f0a" }, { name: Language.I18n.text("ui.t_19dd83f11752"), c: "#ffd60a" },
        { name: Language.I18n.text("ui.t_d486dfbd5fb5"), c: "#30d158" }, { name: Language.I18n.text("ui.t_1d261a8554d2"), c: "#8e8e93" }
    ]

    // ═════════════ CONTROL CENTER LAYOUT ═════════════
    // The Control Center is a 4-column grid. Every control has a size in grid cells; the enabled ones are packed
    // first-fit in the order of `ccControls`, so dragging a control onto another one simply reorders the list.
    readonly property var ccCatalog: [
        { id: "wifi",       label: "Wi-Fi",         glyph: "wifi",       w: 2, h: 1 },
        { id: "bluetooth",  label: Language.I18n.text("ui.t_8bb29098b369"),     glyph: "bluetooth",  w: 2, h: 1 },
        { id: "airplane",   label: Language.I18n.text("ui.t_e3df6ab9ba1b"), glyph: "airplane",   w: 1, h: 1 },
        { id: "focus",      label: Language.I18n.text("ui.t_9d3cab2b5efe"),         glyph: "moon",       w: 2, h: 1 },
        { id: "nightshift", label: Language.I18n.text("ui.t_d9a2bf53437c"),   glyph: "nightshift", w: 1, h: 1 },
        { id: "keepawake",  label: Language.I18n.text("ui.t_7ace19020244"),    glyph: "coffee",     w: 1, h: 1 },
        { id: "darkmode",   label: Language.I18n.text("ui.t_df8c7c89b3e4"),     glyph: "contrast",   w: 1, h: 1 },
        { id: "gaming",     label: Language.I18n.text("ui.t_1311d7944778"),     glyph: "gamepad",    w: 2, h: 1 },
        { id: "record",     label: Language.I18n.text("ui.t_bc3c742893dc"), glyph: "record",  w: 2, h: 1 },
        { id: "mirroring",  label: Language.I18n.text("ui.t_a72c5d7ed939"), glyph: "mirroring", w: 2, h: 1 },
        { id: "airdrop",    label: Language.I18n.text("ui.t_9ccc01839580"),       glyph: "airdrop",    w: 2, h: 1 },
        { id: "nowplaying", label: Language.I18n.text("ui.t_8b2ae991573c"),   glyph: "note",       w: 2, h: 2 },
        { id: "display",    label: Language.I18n.text("ui.t_34e108c0896d"),       glyph: "sun",        w: 4, h: 1 },
        { id: "sound",      label: Language.I18n.text("ui.t_46124e023603"),         glyph: "speaker",    w: 4, h: 1 }
    ]
    readonly property var ccDefault: ["wifi", "nowplaying", "bluetooth", "airplane", "focus", "record", "mirroring", "airdrop", "nightshift", "keepawake", "display", "sound"]
    function ccDef(id) {
        for (var i = 0; i < ccCatalog.length; i++) if (ccCatalog[i].id === id) return ccCatalog[i];
        return null;
    }
    function ccLayout(ids) {
        var cols = 4, occ = [], out = [], seen = {}, rows = 0;
        function isFree(r, c, w, h) {
            for (var y = r; y < r + h; y++) for (var x = c; x < c + w; x++) if (occ[y] && occ[y][x]) return false;
            return true;
        }
        function mark(r, c, w, h) {
            for (var y = r; y < r + h; y++) { if (!occ[y]) occ[y] = []; for (var x = c; x < c + w; x++) occ[y][x] = true; }
        }
        for (var i = 0; i < ids.length; i++) {
            var d = ccDef(ids[i]);
            if (!d || seen[d.id]) continue;
            seen[d.id] = true;
            var placed = false;
            for (var r = 0; !placed; r++) {
                for (var c = 0; c + d.w <= cols; c++) {
                    if (isFree(r, c, d.w, d.h)) {
                        mark(r, c, d.w, d.h);
                        out.push({ id: d.id, col: c, row: r, w: d.w, h: d.h });
                        rows = Math.max(rows, r + d.h);
                        placed = true;
                        break;
                    }
                }
            }
        }
        return { items: out, rows: rows };
    }
    readonly property var ccPlan: ccLayout(ccControls)
    function ccAdd(id) {
        if (ccControls.indexOf(id) < 0) ccControls = ccControls.concat([id]);
    }
    function ccRemove(id) {
        ccControls = ccControls.filter(function (x) { return x !== id; });
    }
    // dropped control `id` with the pointer at (px, py) in grid coordinates: it takes the slot of the nearest control
    function ccDrop(id, px, py, cw, ch, gridH) {
        var order = ccControls.slice(), from = order.indexOf(id);
        if (from < 0) return;
        var to = -1, best = 1e18, it = ccPlan.items;
        for (var i = 0; i < it.length; i++) {
            if (it[i].id === id) continue;
            var o = it[i];
            var cx = o.col * (cw + 10) + (o.w * cw + (o.w - 1) * 10) / 2;
            var cy = o.row * (ch + 10) + (o.h * ch + (o.h - 1) * 10) / 2;
            var dd = (cx - px) * (cx - px) + (cy - py) * (cy - py);
            if (dd < best) { best = dd; to = order.indexOf(o.id); }
        }
        if (py > gridH + 10) to = order.length - 1;
        if (to < 0 || to === from) return;
        order.splice(from, 1);
        order.splice(to, 0, id);
        ccControls = order;
    }

    readonly property string configDir: (Quickshell.env("MACSHELL_SETTINGS_HOME") || Quickshell.env("HOME") + "/.config") + "/macbar"
    readonly property string dockConfigDir: (Quickshell.env("MACSHELL_SETTINGS_HOME") || Quickshell.env("HOME") + "/.config") + "/macdock"
    readonly property int popRoom: 900

    function sh(cmd) { Quickshell.execDetached(["sh", "-c", cmd]); }
    // Ask niri to end its session using its normal quit confirmation.
    function logOut() { Niri.action(["quit"]); }

    // ═════════════ PALETTE ═════════════
    // Auto contrast: what's behind an opening panel is measured (bgTone: 1 bright, -1 dark, 0 unknown) and the panel
    // switches to dark text / light glass on bright backgrounds and the reverse on dark ones; colours cross-fade.
    property bool autoContrast: true
    property int bgTone: 0
    readonly property bool effDark: (autoContrast && bgTone !== 0) ? bgTone < 0 : darkMode
    // Text and its material must change together; fading just the ink passes
    // through the background colour and briefly makes controls disappear.
    readonly property real dk: effDark ? 1 : 0
    onAutoContrastChanged: invalidateTone()
    function mixc(l, d) { return Qt.rgba(l.r + (d.r - l.r) * dk, l.g + (d.g - l.g) * dk, l.b + (d.b - l.b) * dk, l.a + (d.a - l.a) * dk); }
    QtObject {
        id: pal
        readonly property bool dark: root.effDark
        readonly property string fam: root.fontFamily
        readonly property color accent: root.accent
        readonly property color fg: root.mixc(Qt.color("#1D1D1F"), Qt.color("#FFFFFF"))
        readonly property color fg2: root.mixc(Qt.rgba(0, 0, 0, 0.68), Qt.rgba(1, 1, 1, 0.62))
        readonly property color fg3: root.mixc(Qt.rgba(0, 0, 0, 0.48), Qt.rgba(1, 1, 1, 0.34))
        readonly property color tile: root.mixc(Qt.rgba(1, 1, 1, 0.42), Qt.rgba(1, 1, 1, 0.10))
        readonly property color tileBorder: root.mixc(Qt.rgba(1, 1, 1, 0.70), Qt.rgba(1, 1, 1, 0.16))
        readonly property color btnOff: root.mixc(Qt.rgba(0, 0, 0, 0.10), Qt.rgba(1, 1, 1, 0.20))
        readonly property color btnHover: root.mixc(Qt.rgba(0, 0, 0, 0.16), Qt.rgba(1, 1, 1, 0.30))
        readonly property color hover: root.mixc(Qt.rgba(0, 0, 0, 0.09), Qt.rgba(1, 1, 1, 0.14))
        readonly property color sep: root.mixc(Qt.rgba(0, 0, 0, 0.12), Qt.rgba(1, 1, 1, 0.14))
        readonly property color track: root.mixc(Qt.rgba(0, 0, 0, 0.12), Qt.rgba(1, 1, 1, 0.20))
        readonly property color content: dark ? "#1E1E1E" : "#F5F5F7"
        readonly property color card: dark ? "#2B2B2D" : "#FFFFFF"
        readonly property color cardBorder: root.mixc(Qt.rgba(0, 0, 0, 0.08), Qt.rgba(1, 1, 1, 0.07))
        readonly property color switchOff: root.mixc(Qt.rgba(0, 0, 0, 0.16), Qt.rgba(1, 1, 1, 0.22))
    }

    // ═════════════ REUSABLE COMPONENTS ═════════════
    // (inline components don't see ids of this file, so everything arrives through properties / `t` = palette)

    // Hand-drawn monochrome glyphs on an 18×18 grid (no icon theme needed)
    component Glyph: ShellGlyph {}

    // Liquid Glass slab (liquidglass.frag) or a flat translucent fallback
    component LGlass: Item {
        id: g
        property Item backdrop: null
        property url shaderUrl: ""
        property bool liquid: false
        property bool dark: true
        property real cornerR: 20
        property real tint: 0.4             // 0..1, from the translucency setting
        property real thickness: 30
        property real strength: 1.0         // liquid glass strength multiplier
        property real rim: 0.45
        property real grain: 0.03
        property real blur: 5               // backdrop blur radius, px (settings slider)
        property bool debug: false
        signal shaderError()

        MappedRect {
            id: slabMapping
            sourceItem: g; targetItem: g.backdrop
            padding: 82 // shader shadow (10) + sampling margin (72)
        }
        readonly property bool refracting: liquid && root.captureGlass(g)
        GlassFallback {
            visible: !g.refracting
            anchors.fill: parent; radius: g.cornerR
            dark: g.dark; frosting: g.tint; intensity: g.liquid ? g.strength : 0
            blurAmount: g.blur
            blurEnabled: !root.gaming
        }
        Loader {
            anchors.fill: parent
            active: g.refracting && g.backdrop !== null && g.visible
            sourceComponent: Item {
                id: lg
                readonly property real m: 72     // extra backdrop captured around the slab (refraction + blur reach)
                readonly property real p: 10     // shader padding (drop shadow)
                // a Gaussian blur of 8 px or more doesn't need full resolution: blurring at half size is visually identical
                // and costs a quarter of the GPU work, every frame
                readonly property real ds: g.blur >= 8 ? 0.5 : 1.0
                readonly property real bn: g.blur * 1.4 * ds / 64.0     // blur amount in MultiEffect units (at the reduced size)
                ShaderEffectSource {
                    id: bsrc
                    sourceItem: g.backdrop
                    hideSource: true
                    live: true
                    visible: false
                    sourceRect: slabMapping.rect
                    textureSize: Qt.size(Math.max(1, Math.round(sourceRect.width * lg.ds)), Math.max(1, Math.round(sourceRect.height * lg.ds)))
                }
                MultiEffect {
                    id: bblurFx
                    source: bsrc
                    width: bsrc.sourceRect.width * lg.ds; height: bsrc.sourceRect.height * lg.ds
                    blurEnabled: g.blur > 0
                    blurMax: 64
                    blur: Math.min(1.0, lg.bn)
                    autoPaddingEnabled: false
                    visible: false
                }
                // real Gaussian pre-blur of the backdrop (Qt MultiEffect): the glass shader refracts THIS texture,
                // so there are no sampled copies of the background any more
                ShaderEffectSource {
                    id: bblur
                    sourceItem: bblurFx
                    live: true
                    visible: false
                }
                MultiEffect {
                    id: bblur2Fx
                    source: bblur
                    width: bsrc.sourceRect.width * lg.ds; height: bsrc.sourceRect.height * lg.ds
                    blurEnabled: lg.bn > 1.0
                    blurMax: 64
                    blur: Math.max(0.0, Math.min(1.0, lg.bn - 1.0))
                    autoPaddingEnabled: false
                    visible: false
                }
                // second Gaussian pass: only active when the slider goes past a single pass's 64 px limit
                ShaderEffectSource {
                    id: bblur2
                    // the 2nd pass is a pure copy unless the blur radius exceeds one pass: skip it then (same pixels, one GPU pass less)
                    sourceItem: lg.bn > 1.0 ? bblur2Fx : null
                    live: true
                    visible: false
                }
                ShaderEffect {
                    id: fx
                    x: -lg.p; y: -lg.p
                    width: g.width + 2 * lg.p
                    height: g.height + 2 * lg.p
                    fragmentShader: g.shaderUrl
                    onStatusChanged: {
                        console.log("[macbar-glass] shader status:", status, "(0 = compiled, 1 = uncompiled, 2 = error)", log);
                        if (status === ShaderEffect.Error) g.shaderError();
                    }
                    property variant src: lg.bn > 1.0 ? bblur2 : bblur
                    property real padPx: lg.p
                    property vector2d itemSize: Qt.vector2d(width, height)
                    property vector2d glassSize: Qt.vector2d(g.width, g.height)
                    property vector2d srcSize: Qt.vector2d(g.width + 2 * (lg.p + lg.m), g.height + 2 * (lg.p + lg.m))
                    property vector2d srcOffset: Qt.vector2d(lg.m, lg.m)
                    property real pad: lg.p
                    property real radius: g.cornerR
                    property real bezel: Math.min(g.height * 0.36, 26)
                    property real thickness: g.thickness * g.strength * 1.6      // bar popovers: boosted to match the stronger dock glass
                    property real dispersion: 0.06 * g.strength * 1.3
                    property real magnify: 0.05 * g.strength * 1.6
                    property real rim: g.rim
                    property real grain: g.grain * 0.2
                    property real blurPx: g.blur > 0 ? 1.5 : 0
                    property real tintMix: g.dark ? g.tint * 0.55 : GlassTheme.lightTint(g.tint)
                    property real saturation: 1.25
                    property real dark: g.dark ? 1 : 0
                    property real debug: g.debug ? 1 : 0
                    property real shadowAmt: 1
                    property real rimTint: 0
                    property real ringW: 0
                    property real flatInner: 0
                }
            }
        }
    }

    // Context for a group of glass slabs that all read ONE shared backdrop texture, so a whole panel full of
    // tiles and buttons costs a single backdrop capture instead of one per slab.
    component GlassCtx: QtObject {
        property var src: null                          // the ShaderEffectSource holding the backdrop
        property rect srcRect: Qt.rect(0, 0, 1, 1)      // where that texture sits, in `frame` coordinates
        property Item frame: null                       // coordinate space of srcRect (the popover layer)
        property bool liquid: false
        property url shaderUrl: ""
        property bool dark: true
        property real tint: 0.4
        property real strength: 1.0
        property real blur: 5               // base backdrop blur radius, px (settings slider)
        property real blurMul: 1.0          // scales the backdrop blur radius of every slab in this context
        property real liquidMul: 1.0        // scales refraction / dispersion / magnify of every slab in this context
        property real paneOpacity: 1.0      // <1 lets the compositor blur show through the shader pane
        property real rim: 0.45
        property real grain: 0.03
        property bool debug: false
        signal failed()
    }

    // One Liquid Glass slab (tile, button, pill, panel) sampling the shared backdrop of its GlassCtx
    component GGlass: Item {
        id: gg
        required property var gx
        property real cornerR: 22
        property real thickness: 24
        property real strengthMul: 1.0
        property real tintMul: 1.0
        property real shadowAmt: 0.5
        property real flatInner: 0
        readonly property real pad: 10

        MappedRect { id: slabMapping; sourceItem: gg; targetItem: gg.gx.frame }

        readonly property bool refracting: gx.liquid && root.captureGlass(gg)
        GlassFallback {
            visible: !gg.refracting
            anchors.fill: parent; radius: gg.cornerR
            dark: gg.gx.dark; frosting: gg.gx.tint; intensity: gg.gx.liquid ? gg.gx.strength : 0
            blurAmount: gg.gx.blur
            blurEnabled: !root.gaming
        }
        Loader {
            anchors.fill: parent
            active: gg.refracting && gg.gx.src !== null && gg.visible
            sourceComponent: Item {
                ShaderEffect {
                    x: -gg.pad; y: -gg.pad
                    width: gg.width + 2 * gg.pad
                    height: gg.height + 2 * gg.pad
                    fragmentShader: gg.gx.shaderUrl
                    onStatusChanged: if (status === ShaderEffect.Error) gg.gx.failed()
                    opacity: gg.gx.paneOpacity
                    property variant src: gg.gx.src
                    property vector2d itemSize: Qt.vector2d(width, height)
                    property vector2d glassSize: Qt.vector2d(gg.width, gg.height)
                    property vector2d srcSize: Qt.vector2d(gg.gx.srcRect.width / Math.max(.001, slabMapping.scaleX),
                                                         gg.gx.srcRect.height / Math.max(.001, slabMapping.scaleY))
                    property vector2d srcOffset: Qt.vector2d((slabMapping.rect.x - gg.gx.srcRect.x) / Math.max(.001, slabMapping.scaleX) - gg.pad,
                                                           (slabMapping.rect.y - gg.gx.srcRect.y) / Math.max(.001, slabMapping.scaleY) - gg.pad)
                    property real pad: gg.pad
                    property real radius: gg.cornerR
                    property real bezel: Math.min(gg.height * 0.36, 26)
                    property real thickness: gg.thickness * gg.gx.strength * gg.strengthMul * gg.gx.liquidMul * 1.6
                    property real dispersion: 0.06 * gg.gx.strength * gg.strengthMul * gg.gx.liquidMul * 1.3
                    property real magnify: 0.05 * gg.gx.strength * gg.strengthMul * gg.gx.liquidMul * 1.6
                    property real rim: gg.gx.rim
                    property real grain: gg.gx.grain * 0.2
                    property real blurPx: gg.gx.blur * gg.gx.blurMul > 0 ? 1.5 : 0
                    property real tintMix: gg.gx.dark ? gg.gx.tint * 0.55 * gg.tintMul : GlassTheme.lightTint(gg.gx.tint * gg.tintMul)
                    property real saturation: 1.25
                    property real dark: gg.gx.dark ? 1 : 0
                    property real debug: gg.gx.debug ? 1 : 0
                    property real shadowAmt: gg.shadowAmt
                    property real rimTint: 0
                    property real ringW: 0
                    property real flatInner: gg.flatInner
                }
            }
        }
    }

    // Control Center tile: its own Liquid Glass slab (children are laid on top of it)
    component CCTile: Item {
        id: tile
        required property var t
        required property var gx
        property real radius: 34
        GGlass { anchors.fill: parent; gx: tile.gx; cornerR: tile.radius; thickness: 22; shadowAmt: 0; flatInner: 1 }
    }

    // small glass pill button ("Edit Controls", "Done", "Reset")
    component CCPill: Item {
        id: pl
        required property var t
        required property var gx
        property string text: ""
        property bool strong: false
        signal clicked()
        width: plText.implicitWidth + 32; height: 28
        GGlass { anchors.fill: parent; gx: pl.gx; cornerR: 14; thickness: 14; strengthMul: 0.6; shadowAmt: 0; flatInner: 1 }
        Rectangle {
            anchors.fill: parent; radius: 14
            color: pla.containsMouse ? (pl.t.dark ? Qt.rgba(1, 1, 1, 0.04) : Qt.rgba(1, 1, 1, 0.09)) : Qt.rgba(1, 1, 1, 0)
        }
        Text {
            id: plText
            anchors.centerIn: parent
            text: pl.text
            color: pl.t.fg; font.family: pl.t.fam; font.pixelSize: 12
            font.weight: pl.strong ? Font.DemiBold : Font.Normal
        }
        MouseArea { id: pla; anchors.fill: parent; hoverEnabled: true; onClicked: pl.clicked() }
    }

    // round glyph button: Liquid Glass disc, accent-coloured glass when "on"
    // Contour glow (hover): a thin light line along the rounded outline + soft halo, brightest near the cursor
    component ContourGlow: ShaderEffect {
        id: cgl
        property real cornerR: 24
        property bool hovered: false
        property point at: Qt.point(width / 2, height / 2)      // cursor, in the shape's coordinates
        property real pad: 14
        property color glowColor: "white"
        anchors.fill: parent
        anchors.margins: -pad
        fragmentShader: Qt.resolvedUrl("contourglow.frag.qsb")
        property vector2d itemSize: Qt.vector2d(width, height)
        property vector2d mouse: Qt.vector2d(at.x, at.y)
        property real cornerRadius: cornerR
        property real amount: hovered ? 1 : 0
        Behavior on amount { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
        property real spread: Math.max(40, Math.min(width, height) * 0.9)
        property vector4d tint: Qt.vector4d(glowColor.r, glowColor.g, glowColor.b, 1)
        visible: amount > 0.005
    }

    component CCBtn: Item {
        id: b
        required property var t
        required property var gx
        property string kind: ""
        property bool on: false
        property real level: 3
        property bool flag: false
        property string onTint: ""
        property real d: 40
        property real shadow: 0
        signal clicked()
        property bool bounce: false
        width: d; height: d
        scale: (bounce && bma.pressed) ? 0.88 : 1
        Behavior on scale { NumberAnimation { duration: 230; easing.type: Easing.OutBack; easing.overshoot: 3.2 } }
        GGlass { anchors.fill: parent; gx: b.gx; cornerR: b.d / 2; thickness: 14; strengthMul: 0.6; shadowAmt: b.shadow; flatInner: 1 }
        Rectangle {
            anchors.fill: parent
            radius: b.d / 2
            color: b.on ? (b.onTint !== "" ? Qt.color(b.onTint) : Qt.rgba(b.t.accent.r, b.t.accent.g, b.t.accent.b, 0.92))
                        : (bma.containsMouse ? (b.t.dark ? Qt.rgba(1, 1, 1, 0.16) : Qt.rgba(1, 1, 1, 0.34)) : Qt.rgba(1, 1, 1, 0))
            Behavior on color { ColorAnimation { duration: 320; easing.type: Easing.OutCubic } }
        }
        // state flip: the icon dips, turns a touch and springs back (motion), while the fill fades
        property real pop: 0
        onOnChanged: popAnim.restart()
        SequentialAnimation {
            id: popAnim
            NumberAnimation { target: b; property: "pop"; to: 1; duration: 120; easing.type: Easing.OutCubic }
            NumberAnimation { target: b; property: "pop"; to: 0; duration: 420; easing.type: Easing.OutQuint }
        }
        Glyph {
            scale: 1 - 0.22 * b.pop
            rotation: (b.on ? -14 : 14) * b.pop
            anchors.centerIn: parent
            width: b.d * 0.46; height: width
            kind: b.kind; level: b.level; flag: b.flag
            color: b.on ? "white" : b.t.fg
        }
        MouseArea { id: bma; anchors.fill: parent; hoverEnabled: true; onClicked: b.clicked() }
    }

    // thin-line slider: icon at each end, slim rounded track between them
    component CCSlider: LevelSlider {}

    // one device row of the sound popover: round icon (accent when it is the active device), name, optional second line
    component AudioRow: Item {
        id: ar
        required property var t
        property string title: ""
        property string sub: ""
        property string kind: "speaker"
        property bool selected: false
        signal clicked()
        width: parent ? parent.width : 300
        height: 46
        Rectangle {
            anchors.fill: parent
            radius: 12
            color: ar.t.hover
            opacity: arMa.containsMouse ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 90 } }
        }
        Rectangle {
            x: 8
            anchors.verticalCenter: parent.verticalCenter
            width: 32; height: 32; radius: 16
            color: ar.selected ? ar.t.accent : ar.t.btnOff
            Behavior on color { ColorAnimation { duration: 120 } }
            Glyph { anchors.centerIn: parent; width: 16; height: 16; kind: ar.kind; level: 3; color: ar.selected ? "white" : ar.t.fg }
        }
        Column {
            x: 50
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - 50 - 14
            spacing: 1
            Text {
                width: parent.width
                elide: Text.ElideRight
                text: ar.title
                color: ar.t.fg
                font.family: ar.t.fam; font.pixelSize: 13
                font.weight: ar.selected ? Font.DemiBold : Font.Normal
            }
            Text {
                visible: ar.sub !== ""
                width: parent.width
                elide: Text.ElideRight
                text: ar.sub
                color: ar.t.fg2
                font.family: ar.t.fam; font.pixelSize: 11
            }
        }
        MouseArea { id: arMa; anchors.fill: parent; hoverEnabled: true; onClicked: ar.clicked() }
    }

    // ── notification card contents (used by the popups and by the notification centre) ──
    component NotifBody: Item {
        id: nb
        required property var t
        property string app: ""
        property string summary: ""
        property string body: ""
        property string icon: ""
        property int urgency: 1
        property real stamp: 0
        property real nowMs: 0
        property bool showClose: false
        property bool showTime: false
        signal closeClicked()
        width: parent ? parent.width : 340
        height: Math.max(74, textCol.height + 30)

        readonly property string agoText: {
            var m = Math.floor((nb.nowMs - nb.stamp) / 60000);
            return m < 1 ? "now" : (m < 60 ? m + "m ago" : (m < 1440 ? Math.floor(m / 60) + "h ago" : Math.floor(m / 1440) + "d ago"));
        }

        Item {
            x: 14; y: 15; width: 44; height: 44
            Rectangle {
                anchors.fill: parent; radius: 10
                visible: nimg.status !== Image.Ready
                color: nb.t.accent
                Glyph { anchors.centerIn: parent; width: 24; height: 24; kind: "bell"; color: "white" }
            }
            Image {
                id: nimg
                anchors.fill: parent
                visible: status === Image.Ready
                source: nb.icon
                sourceSize.width: 96; sourceSize.height: 96
                fillMode: Image.PreserveAspectFit
                asynchronous: true; smooth: true
            }
        }
        Column {
            id: textCol
            // a notification updated in place (same id, new text): blur out, refocus on the new wording
            property real refocus: 0
            layer.enabled: refocus > 0.001
            layer.effect: MultiEffect { blurEnabled: true; blurMax: 32; blur: textCol.refocus; autoPaddingEnabled: true }
            opacity: 1 - 0.5 * refocus
            NumberAnimation { id: refocusAnim; target: textCol; property: "refocus"; from: 1; to: 0; duration: 460; easing.type: Easing.OutQuint }
            Connections {
                target: nb
                function onSummaryChanged() { refocusAnim.restart(); }
                function onBodyChanged() { refocusAnim.restart(); }
            }
            x: 70; y: 14
            width: parent.width - 70 - 44
            spacing: 1
            Text {
                width: parent.width
                text: nb.urgency === 2 ? Language.I18n.text("ui.t_3299e1c9c571") : nb.app
                horizontalAlignment: /[\u0590-\u08ff]/.test(text) ? Text.AlignRight : Text.AlignLeft
                visible: text !== ""
                color: nb.urgency === 2 ? nb.t.fg2 : nb.t.fg
                font.family: nb.t.fam; font.pixelSize: nb.urgency === 2 ? 12 : 14
                font.weight: Font.DemiBold
                font.letterSpacing: nb.urgency === 2 ? 0.4 : 0
                elide: Text.ElideRight
            }
            Text {
                width: parent.width
                text: nb.summary
                horizontalAlignment: /[\u0590-\u08ff]/.test(text) ? Text.AlignRight : Text.AlignLeft
                visible: text !== ""
                color: nb.t.fg
                font.family: nb.t.fam; font.pixelSize: 14; font.weight: Font.Bold
                wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
            }
            Text {
                width: parent.width
                text: nb.body
                horizontalAlignment: /[\u0590-\u08ff]/.test(text) ? Text.AlignRight : Text.AlignLeft
                visible: text !== ""
                color: nb.t.fg
                font.family: nb.t.fam; font.pixelSize: 13
                wrapMode: Text.Wrap; maximumLineCount: 3; elide: Text.ElideRight
            }
        }
        Text {
            visible: nb.showTime && !nb.showClose
            anchors.right: parent.right; anchors.rightMargin: 14
            y: 15
            text: nb.agoText
            color: nb.t.fg2
            font.family: nb.t.fam; font.pixelSize: 12
        }
        Rectangle {
            id: xbtn
            visible: nb.showClose
            anchors.right: parent.right; anchors.rightMargin: 10
            y: 10
            width: 22; height: 22; radius: 11
            color: xma.containsMouse ? nb.t.btnHover : nb.t.btnOff
            Glyph { anchors.centerIn: parent; width: 12; height: 12; kind: "close"; color: nb.t.fg }
            MouseArea { id: xma; anchors.fill: parent; hoverEnabled: true; onClicked: nb.closeClicked() }
        }
    }

    // ── settings window pieces ──
    component PRow: Item {
        id: r
        required property var t
        property string title: ""
        default property alias control: slot.data
        width: parent ? parent.width : 0
        height: 42
        Rectangle { visible: r.y > 0.5; x: 14; width: parent.width - 14; height: 1; color: r.t.sep }
        Text {
            x: 14; anchors.verticalCenter: parent.verticalCenter
            text: r.title; color: r.t.dark ? "#F5F5F7" : "#1D1D1F"
            font.family: r.t.fam; font.pixelSize: 13
        }
        Item {
            id: slot
            anchors.right: parent.right; anchors.rightMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            width: childrenRect.width; height: childrenRect.height
        }
    }
    component PCard: Rectangle {
        required property var t
        default property alias content: pcol.data
        width: parent ? parent.width : 0
        height: pcol.implicitHeight
        radius: 10
        color: t.card
        border.width: 1
        border.color: t.cardBorder
        Column { id: pcol; width: parent.width }
    }
    component PSwitch: Item {
        id: sw
        required property var t
        property bool checked: false
        signal toggled(bool value)
        width: 38; height: 22
        Rectangle { anchors.fill: parent; radius: 11; color: sw.checked ? sw.t.accent : sw.t.switchOff }
        Rectangle {
            x: sw.checked ? 18 : 2; y: 2; width: 18; height: 18; radius: 9; color: "white"
            Behavior on x { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
        }
        MouseArea { anchors.fill: parent; onClicked: sw.toggled(!sw.checked) }
    }
    component PSlider: Item {
        id: ps
        required property var t
        property real from: 0
        property real to: 1
        property real value: 0
        signal moved(real v)
        width: 190; height: 22
        readonly property real pos: to > from ? Math.max(0, Math.min(1, (value - from) / (to - from))) : 0
        Rectangle { y: 9; width: parent.width; height: 4; radius: 2; color: ps.t.track }
        Rectangle { y: 9; width: ps.pos * (ps.width - 20) + 10; height: 4; radius: 2; color: ps.t.accent }
        Rectangle {
            x: ps.pos * (ps.width - 20); y: 1; width: 20; height: 20; radius: 10; color: "white"
            border.width: 1; border.color: Qt.rgba(0, 0, 0, 0.16)
        }
        MouseArea {
            anchors.fill: parent
            preventStealing: true
            function setFrom(mx) {
                var p = Math.max(0, Math.min(1, (mx - 10) / (ps.width - 20)));
                ps.moved(Math.round((ps.from + p * (ps.to - ps.from)) * 100) / 100);
            }
            onPressed: mouse => setFrom(mouse.x)
            onPositionChanged: mouse => { if (pressed) setFrom(mouse.x); }
        }
    }
    component PSeg: Item {
        id: sg
        required property var t
        property var model: []
        property int current: 0
        property real segWidth: 100
        signal picked(int index)
        width: model.length * segWidth + 4; height: 26
        Rectangle { anchors.fill: parent; radius: 7; color: sg.t.btnOff }
        Rectangle {
            y: 2; x: 2 + sg.current * sg.segWidth; width: sg.segWidth; height: parent.height - 4; radius: 5
            color: sg.t.dark ? "#636366" : "#FFFFFF"
            Behavior on x { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
        }
        Row {
            x: 2; y: 2
            Repeater {
                model: sg.model
                delegate: Item {
                    required property var modelData
                    required property int index
                    width: sg.segWidth; height: sg.height - 4
                    Text {
                        anchors.centerIn: parent; text: parent.modelData
                        color: sg.t.dark ? "#F5F5F7" : "#1D1D1F"
                        font.family: sg.t.fam; font.pixelSize: 12
                    }
                    MouseArea { anchors.fill: parent; onClicked: sg.picked(parent.index) }
                }
            }
        }
    }

    // ═════════════ STATE & DATA SOURCES ═════════════
    SystemClock { id: clock; precision: root.showSeconds ? SystemClock.Seconds : SystemClock.Minutes }

    readonly property string clockText: {
        var d = clock.date;
        var tf = root.use24h ? (root.showSeconds ? "HH:mm:ss" : "HH:mm") : (root.showSeconds ? "h:mm:ss AP" : "h:mm AP");
        var t = Language.I18n.formatDateTime(d, tf);
        return root.showDate ? Language.I18n.formatDateTime(d, "ddd d MMM") + "  " + t : t;
    }

    // active app
    function lookup(appId) {
        if (!appId) return null;
        var builtin = Utilities.entry(appId, key => { if (root.hub && root.hub.openUtility) root.hub.openUtility(key); }, value => Language.I18n.legacy(value), Language.I18n.activeLanguage);
        if (builtin) return builtin;
        var e = DesktopEntries.byId(appId);
        if (!e && DesktopEntries.heuristicLookup) e = DesktopEntries.heuristicLookup(appId);
        return e;
    }
    readonly property var activeTl: Niri.activeToplevel
    readonly property string activeAppId: activeTl ? (activeTl.appId || "") : ""
    readonly property string appName: {
        if (activeAppId === "") return Language.I18n.text("ui.t_9bd88f2485ac");
        // MacShell's own windows (all "org.quickshell")
        if (activeAppId === "org.quickshell" || activeAppId === "dev.noctalia.noctalia-qs") return (Utilities.windowId(activeTl.title) || activeTl.title === "App Store") ? Utilities.displayTitle(activeAppId, activeTl.title, value => Language.I18n.legacy(value), Language.I18n.activeLanguage)
                                                     : (activeTl.title === "macshell Settings" ? Language.I18n.text("ui.t_1f87f883cc7e") : "MacShell");
        var e = lookup(activeAppId);
        return e ? e.name : activeAppId;
    }
    readonly property var activeWin: Niri.activeToplevel ? Niri.activeToplevel.data : null
    function refreshActive() { swTrack(); }
    onActiveTlChanged: swTrack()
    readonly property var menuTitles: [
        { id: "apple", label: "" },
        { id: "app", label: appName, bold: true },
        { id: "file", label: Language.I18n.text("ui.t_50009ce1da4d") },
        { id: "edit", label: Language.I18n.text("ui.t_464c4ffd019e") },
        { id: "view", label: Language.I18n.text("ui.t_dcc839a4015c") },
        { id: "window", label: Language.I18n.text("ui.t_19734a1b58ca") },
        { id: "help", label: Language.I18n.text("ui.t_b79cac926e0b") }
    ]

    // audio
    readonly property real maxVolume: 1.5
    readonly property var sink: Pipewire.defaultAudioSink
    PwObjectTracker { objects: [root.sink] }
    readonly property real volume: (sink && sink.audio) ? sink.audio.volume : 0
    readonly property bool muted: (sink && sink.audio) ? sink.audio.muted : false
    readonly property bool osdReady: levelFeedback.ready
    LevelOsdState {
        id: levelFeedback
        onShown: (kind, value, muted) => {
            if (kind === "volume" && !muted) root.playSound("pop", .55 + .45 * Math.min(1, value));
        }
    }
    function osdQuiet(kind, ms) { levelFeedback.quiet(kind, ms); }
    // ── UI sounds (synthesized macOS-style set in ~/.local/share/sounds/macshell, see macshell-make-sounds.py) ──
    readonly property string soundDir: Quickshell.env("HOME") + "/.local/share/sounds/macshell"
    property var soundLast: ({})
    function playSound(name, vol) {
        if (!uiSounds || gaming) return;
        var now = Date.now(), last = soundLast[name] || 0;
        if (now - last < 90) return;                 // a burst of volume steps → one pop per step, not a buzz
        soundLast[name] = now;
        Quickshell.execDetached(["pw-play", "--volume=" + (vol === undefined ? 0.8 : vol), soundDir + "/" + name + ".wav"]);
    }
    onChargingChanged: if (charging && osdReady) playSound("charge")
    onVolumeChanged: levelFeedback.show("volume", volume, muted)
    onMutedChanged: levelFeedback.show("volume", volume, muted)
    function setVolume(v, feedback = false) {
        if (!sink || !sink.audio) return;
        var next = Math.max(0, Math.min(maxVolume, v));
        osdQuiet("volume", 600);
        sink.audio.muted = false;
        sink.audio.volume = next;
        if (feedback) levelFeedback.show("volume", next, false, true);
    }
    function toggleMute(feedback = false) {
        if (!sink || !sink.audio) return;
        var next = !sink.audio.muted;
        osdQuiet("volume", 600);
        sink.audio.muted = next;
        if (feedback) levelFeedback.show("volume", volume, next, true);
    }
    readonly property var micSource: Pipewire.defaultAudioSource
    PwObjectTracker { objects: [root.micSource] }
    readonly property bool micMuted: (micSource && micSource.audio) ? micSource.audio.muted : true
    function toggleMicMute(feedback = false) {
        if (!micSource || !micSource.audio) return;
        var next = !micSource.audio.muted;
        osdQuiet("microphone", 600);
        micSource.audio.muted = next;
        if (feedback) levelFeedback.show("microphone", micVolume, next, true);
    }
    readonly property real volLevel: muted || volume <= 0.001 ? 0 : (volume < 0.34 ? 1 : (volume < 0.67 ? 2 : 3))
    readonly property real micVolume: (micSource && micSource.audio) ? micSource.audio.volume : 0
    function setMicVolume(v) { if (micSource && micSource.audio) { micSource.audio.muted = false; micSource.audio.volume = Math.max(0, Math.min(1, v)); } }

    // Device lists come straight from the PipeWire graph, so plugging in headphones / a headset updates the picker at once.
    PwObjectTracker { objects: Pipewire.nodes.values }
    function audioDevices(wantOutput) {
        var ns = Pipewire.nodes.values, out = [];
        for (var i = 0; i < ns.length; i++) {
            var n = ns[i];
            if (!n || !n.audio || n.isStream) continue;
            var isOut = n.type !== undefined ? ((n.type & PwNodeType.Sink) !== 0 && (n.type & PwNodeType.Source) === 0) : n.isSink;
            var isIn = n.type !== undefined ? ((n.type & PwNodeType.Source) !== 0 && (n.type & PwNodeType.Sink) === 0) : !n.isSink;
            if (wantOutput ? isOut : isIn) out.push(n);
        }
        out.sort(function (a, b) { return String(a.description || a.name).localeCompare(String(b.description || b.name)); });
        return out;
    }
    // Group playback streams by application: one control per app, even if it owns multiple output streams.
    property int audioTick: 0
    function audioApps() {
        var tick = audioTick, ns = Pipewire.nodes.values, groups = {}, out = [];
        for (var i = 0; i < ns.length; i++) {
            var n = ns[i];
            if (!n || !n.audio || !n.isStream) continue;
            var playback = n.type !== undefined ? ((n.type & PwNodeType.AudioOutStream) !== 0) : !n.isSink;
            if (!playback) continue;
            var p = n.properties || {};
            var name = String(p["application.name"] || p["node.description"] || n.description || p["application.process.binary"] || p["node.name"] || n.name || "App");
            if (name.toLowerCase() === "peak detect") continue;
            var key = String(p["application.id"] || p["application.process.binary"] || name).toLowerCase();
            if (!groups[key]) groups[key] = { key: key, name: name, nodes: [], volume: 0, muted: true };
            var g = groups[key];
            g.nodes.push(n);
            g.volume += Math.max(0, Math.min(maxVolume, Number(n.audio.volume) || 0));
            g.muted = g.muted && !!n.audio.muted;
        }
        for (var k in groups) {
            var g = groups[k];
            g.volume /= Math.max(1, g.nodes.length);
            out.push(g);
        }
        out.sort(function (a, b) { return a.name.localeCompare(b.name); });
        return out;
    }
    readonly property var appAudioStreams: audioApps()
    function setAppVolume(app, v) {
        if (!app || !app.nodes) return;
        osdQuiet("volume", 600);
        var value = Math.max(0, Math.min(maxVolume, v));
        for (var i = 0; i < app.nodes.length; i++) {
            var n = app.nodes[i];
            if (n && n.audio) { n.audio.muted = false; n.audio.volume = value; }
        }
    }
    readonly property var audioOutputs: audioDevices(true)
    readonly property var audioInputs: audioDevices(false)
    function audioKind(n, isOut) {
        if (!isOut) return "mic";
        var p = n.properties || {}, f = String(p["device.form-factor"] || "").toLowerCase();
        var t = (String(n.description) + " " + String(n.name)).toLowerCase();
        if (f === "headphone" || f === "headset" || /headphone|headset|airpods|buds|bluez/.test(t)) return "headphones";
        if (f === "hdmi" || f === "tv" || f === "monitor" || /hdmi|displayport|display port/.test(t)) return "monitor";
        return "speaker";
    }
    // "Family 17h HD Audio Controller Analog Stereo" -> ["Family 17h HD Audio Controller", "Analog Stereo"]
    function audioSplit(d) {
        d = String(d || "");
        var m = /^(.*?)\s+((?:Analog|Digital|Pro|Stereo|Mono|Speaker|Headphones|Headset|Microphone|Line|HDMI|DisplayPort|S\/PDIF|Surround)\b.*)$/i.exec(d);
        return (m && m[1].length > 2) ? [m[1], m[2]] : [d, ""];
    }
    function chooseAudio(n) {      // make this device the default; wpctl ships with WirePlumber, pactl is the fallback
        if (!n) return;
        osdQuiet("volume", 1500);
        Quickshell.execDetached(["sh", "-c", "wpctl set-default \"$1\" 2>/dev/null || pactl \"$3\" \"$2\"", "sh", String(n.id), String(n.name),
                                 (n.type !== undefined ? ((n.type & PwNodeType.Sink) !== 0) : n.isSink) ? "set-default-sink" : "set-default-source"]);
    }

    // Battery and system power profiles are shared by all displays and Settings.
    property alias battery: batteryControl
    property alias power: powerControl
    BatteryControl { id: batteryControl }
    PowerControl { id: powerControl; gaming: root.gaming }
    readonly property bool hasBattery: batteryControl.present
    readonly property real batPct: batteryControl.percentage
    readonly property bool charging: batteryControl.charging

    // media
    readonly property var player: {
        var ps = Mpris.players.values, best = null;
        for (var i = 0; i < ps.length; i++) {
            if (ps[i].isPlaying) return ps[i];
            if (!best) best = ps[i];
        }
        return best;
    }

    // NetworkManager state is shared by settings and every bar surface.
    property alias wifi: wifiControl
    readonly property bool wifiOn: wifiControl.enabled
    readonly property string wifiSsid: wifiControl.ssid
    readonly property int wifiSignal: wifiControl.strength
    readonly property bool ethernetUp: wifiControl.ethernet
    readonly property bool showEthernet: ethernetUp && wifiSsid === ""
    readonly property int wifiLevel: !wifiOn || wifiSsid === "" ? 0 : sigLevel(wifiSignal)
    readonly property var wifiNets: wifiControl.networks
    readonly property bool wifiScanning: wifiControl.scanning
    readonly property string wifiBusy: wifiControl.selected && wifiControl.busy !== "" ? wifiControl.selected.ssid : ""
    readonly property string wifiError: wifiControl.error
    function sigLevel(s) { return s > 66 ? 3 : s > 33 ? 2 : 1; }
    function refreshWifi() { wifiControl.refresh(); }
    function toggleWifi() { wifiControl.power(!wifiOn); }
    function scanWifi() { wifiControl.scan(); }
    function wifiJoin(network) { root.interactionScreen = Niri.focusedMonitor ? Niri.focusedMonitor.name : ""; wifiControl.pick(network); }
    function connectWifi(ssid, password) {
        var net = wifiNets.find(n => n.ssid === ssid);
        if (net) wifiControl.join(net, password);
    }
    function disconnectWifi() { var net = wifiNets.find(n => n.inUse); if (net) wifiControl.pick(net); }
    function splitNm(line) {
        var out = [], cur = "";
        for (var i = 0; i < line.length; i++) {
            if (line[i] === "\\" && i + 1 < line.length) cur += line[++i];
            else if (line[i] === ":") { out.push(cur); cur = ""; }
            else cur += line[i];
        }
        out.push(cur); return out;
    }
    WifiControl {
        id: wifiControl
        active: root.settingsReady
        onPromptRequested: root.controlRequested("wifijoin")
        onPromptChanged: if (!prompt) root.controlRequested("close-wifijoin")
    }
    Timer { id: wifiAfter; interval: 1200; onTriggered: { root.scanWifi(); root.refreshWifi(); root.refreshConnections(); } }
    function refreshConnections() { if (!connProc.running) connProc.running = true; }
    Process {
        id: connProc
        command: ["sh", "-c", "nmcli -t -f NAME,TYPE,DEVICE connection show 2>/dev/null"]
        stdout: StdioCollector {
            onStreamFinished: {
                var rows = [], lines = text.split("\n");
                for (var i = 0; i < lines.length; i++) {
                    if (!lines[i]) continue;
                    var f = root.splitNm(lines[i]);
                    if (f.length < 3) continue;
                    var type = f[1];
                    if (type !== "vpn" && type !== "802-3-ethernet") continue;
                    rows.push({ name: f[0], type: type, device: f[2] === "--" ? "" : f[2], active: f[2] !== "--" });
                }
                rows.sort(function (a,b) { return (b.active?1:0)-(a.active?1:0); });
                root.otherConnections = rows;
            }
        }
    }
    function toggleConnection(c) {
        if (!c) return;
        var args = c.active ? ["nmcli", "connection", "down", "id", c.name] : ["nmcli", "connection", "up", "id", c.name];
        Quickshell.execDetached(args); connectionRefresh.restart();
    }
    Timer { id: connectionRefresh; interval: 1200; onTriggered: root.refreshConnections() }

    // One Bluetooth model for Control Center, the menu bar and System Settings.
    property alias bluetooth: bluetoothControl
    readonly property bool btOn: bluetoothControl.enabled
    readonly property int btConnected: bluetoothControl.connected
    BluetoothControl {
        id: bluetoothControl; active: root.settingsReady
        onPromptRequested: root.controlRequested("btpair")
        onPromptChanged: if (!prompt) root.controlRequested("close-btpair")
    }
    function refreshBt() { bluetoothControl.refresh(); }
    function toggleBt() { bluetoothControl.togglePower(); }
    readonly property bool airplane: !wifiOn && !btOn
    function toggleAirplane() {
        var turnOn = airplane;
        sh(turnOn ? "rfkill unblock all" : "rfkill block all");
        wifiControl.power(turnOn);
        settleTimer.restart();
    }
    Timer { id: settleTimer; interval: 900; onTriggered: { root.refreshWifi(); root.refreshBt(); } }

    // brightness
    property real brightness: 0.5
    function refreshBrightness() { brightnessControl.refresh(); }
    BrightnessControl {
        id: brightnessControl; active: root.settingsReady
        onValueChanged: root.brightness = value
    }
    Timer {
        id: brightApply
        interval: 40
        onTriggered: Quickshell.execDetached(["brightnessctl", "-q", "set", Math.max(1, Math.round(root.brightness * 100)) + "%"])
    }
    function setBrightness(v, feedback = false) {
        osdQuiet("brightness", 1800);
        brightness = Math.max(0.01, Math.min(1, v));
        brightApply.restart();
        if (feedback) levelFeedback.show("brightness", brightness, false, true);
    }
    onBrightnessChanged: levelFeedback.show("brightness", brightness)
    // ═════════════ KEYBOARD LAYOUT ═════════════
    // niri announces every change with an `activelayout` event, so the label updates immediately (no polling).
    readonly property var kbNames: ({
        us: "English (US)", gb: "English (UK)", ca: "Canadian", au: "English (Australian)", ie: "Irish", in: "Indian",
        ru: "Russian", ua: "Ukrainian", by: "Belarusian", bg: "Bulgarian", rs: "Serbian", hr: "Croatian", si: "Slovenian", mk: "Macedonian",
        de: "German", at: "German (Austria)", ch: "Swiss", fr: "French", be: "Belgian", es: "Spanish", latam: "Spanish (Latin American)",
        it: "Italian", pt: "Portuguese", br: "Portuguese (Brazil)", nl: "Dutch", se: "Swedish", no: "Norwegian", dk: "Danish", fi: "Finnish",
        is: "Icelandic", pl: "Polish", cz: "Czech", sk: "Slovak", hu: "Hungarian", ro: "Romanian", gr: "Greek", tr: "Turkish",
        il: "Hebrew", ara: "Arabic", ir: "Persian", pk: "Urdu", bd: "Bangla", th: "Thai", vn: "Vietnamese", jp: "Japanese", kr: "Korean",
        cn: "Chinese", tw: "Taiwanese", mn: "Mongolian", ge: "Georgian", am: "Armenian", kz: "Kazakh", ee: "Estonian", lv: "Latvian", lt: "Lithuanian"
    })
    function refreshKeyboardLayout() {
        var names = Niri.keyboard.names || [];
        root.kbLayouts = names.map(function(name) {
            var match = Object.keys(root.kbNames).find(function(k) { return root.kbNames[k].split(" (")[0] === name.split(" (")[0]; });
            return { code: match || name.substring(0, 2).toLowerCase(), name: name };
        });
        root.kbSetActive(names[Niri.keyboard.current_idx] || "", Niri.keyboard.current_idx);
    }
    Connections { target: Niri; function onKeyboardChanged() { root.refreshKeyboardLayout(); } }
    function kbSetActive(name, idx) {
        var L = kbLayouts, found = -1, i;
        var n = String(name || "").toLowerCase();
        if (idx !== undefined && idx !== null && idx >= 0 && idx < L.length) found = idx;
        for (i = 0; found < 0 && i < L.length; i++) if (L[i].name.toLowerCase() === n) found = i;
        for (i = 0; found < 0 && i < L.length; i++) if (n !== "" && n.indexOf(L[i].name.toLowerCase().split(" ")[0]) === 0) found = i;
        if (found >= 0) {
            kbIndex = found;
            keyboardLayout = L[found].code.substring(0, 2).toUpperCase();
        } else if (n !== "") {
            keyboardLayout = String(name).replace(/[^A-Za-z]/g, "").substring(0, 2).toUpperCase() || "??";
        }
    }
    function switchKeyboardLayout(i) {
        var n = kbLayouts.length;
        if (n < 2) return;
        i = ((i % n) + n) % n;
        kbIndex = i; keyboardLayout = kbLayouts[i].code.substring(0, 2).toUpperCase();    // show it right away, the event confirms it
        Niri.action(["switch-layout", String(i)]);
    }
    function cycleKeyboardLayout(step) { switchKeyboardLayout(kbIndex + (step === undefined ? 1 : step)); }
    // ═════════════ PRIVACY INDICATORS ═════════════
    // Computed from the live PipeWire graph: a link only counts while it is Active, so the dots appear the moment an app starts
    // using the microphone / a camera / a screen-share and vanish as soon as it stops. No polling, no pw-dump.
    PwObjectTracker { objects: Pipewire.linkGroups.values }
    function computePrivacy() {
        var mic = [], cam = [], share = [], L = Pipewire.linkGroups.values;
        function add(list, name) { if (list.indexOf(name) < 0) list.push(name); }
        for (var i = 0; i < L.length; i++) {
            var g = L[i];
            if (!g || g.state !== PwLinkState.Active) continue;
            var s = g.source, t = g.target;
            if (!s || !t || s.type === undefined) continue;
            var tp = t.properties || {}, sp = s.properties || {};
            if (String(tp["application.name"]).indexOf("macshell-preview") >= 0) continue;
            var who = String(tp["application.name"] || tp["node.description"] || t.description || tp["node.name"] || t.name || "An app")
                .replace(/\s+(input|output)$/i, "");
            if ((t.type & PwNodeType.AudioInStream) === PwNodeType.AudioInStream) {
                // an app is recording from a real source (a monitor of a sink is "listening to the computer", not a microphone)
                if ((s.type & PwNodeType.Sink) !== 0) continue;
                if (String(tp["media.name"]).toLowerCase() === "peak detect" || String(tp["application.id"]).indexOf("pavucontrol") >= 0) continue;
                add(mic, who);
            } else if ((t.type & PwNodeType.Video) !== 0 && (s.type & PwNodeType.Video) !== 0) {
                var isCam = sp["device.api"] !== undefined || String(sp["media.role"]) === "Camera"
                            || String(sp["node.name"]).indexOf("v4l2") === 0 || String(sp["node.name"]).indexOf("libcamera") === 0;
                add(isCam ? cam : share, who);
            }
        }
        return { mic: mic, cam: cam, share: share };
    }
    readonly property var privacy: computePrivacy()
    readonly property bool privacyAny: privacy.mic.length > 0 || privacy.cam.length > 0 || privacy.share.length > 0 || recording
    readonly property var privacyDots: {
        var a = [];
        if (privacy.mic.length > 0) a.push("#FF9F0A");
        if (privacy.cam.length > 0) a.push("#30D158");
        if (privacy.share.length > 0 || recording || mirroring.sending) a.push("#BF5AF2");
        return a;
    }
    readonly property var privacyRows: {
        var a = [];
        if (privacy.mic.length > 0) a.push({ k: "mic", glyph: "mic", c: "#FF9F0A", title: Language.I18n.text("ui.t_186352a881d0"), sub: privacy.mic.join(", ") });
        if (privacy.cam.length > 0) a.push({ k: "cam", glyph: "camera", c: "#30D158", title: Language.I18n.text("ui.t_03494b0d1f80"), sub: privacy.cam.join(", ") });
        if (privacy.share.length > 0) a.push({ k: "share", glyph: "monitor", c: "#BF5AF2", title: Language.I18n.text("ui.t_0cca2a16a1da"), sub: privacy.share.join(", ") });
        if (recording) a.push({ k: "rec", glyph: "monitor", c: "#BF5AF2", title: Language.I18n.text("ui.t_bc3c742893dc"), sub: Language.I18n.text("ui.t_6d21b74516ed") + recTime() });
        if (mirroring.sending) a.push({ k: "airplay", glyph: "mirroring", c: "#BF5AF2", title: Language.I18n.text("ui.t_5d9bbb593f62"), sub: mirroring.label });
        return a;
    }
    // Recording owns its process and audio routes; all capture consumers share quiet.
    property alias recorder: recordingControl
    readonly property bool recRun: recordingControl.quiet
    property string recordOutput: ""
    property string recordMicrophone: ""
    property string recordSink: ""
    property string recordAudio: "none"
    RecordingControl {
        id: recordingControl; active: root.settingsReady
        output: root.recordOutput; microphone: root.recordMicrophone; sink: root.recordSink; audio: root.recordAudio
        onOutputChanged: root.recordOutput = output
        onMicrophoneChanged: root.recordMicrophone = microphone
        onSinkChanged: root.recordSink = sink
        onAudioChanged: root.recordAudio = audio
        onFileChanged: root.recordFile = file
        onHideRequested: root.controlRequested("close-record")
        onShowRequested: root.controlRequested("record")
    }
    function toggleRecording() {
        if (recordingControl.busy) recordingControl.stop();
        else { recordingControl.prepare(); root.controlRequested("record"); }
    }
    function recTime() { return recordingControl.timeLabel(); }
    property alias mirroring: mirroringControl
    ScreenMirroringControl {
        id: mirroringControl
        active: root.settingsReady
        watching: root.activeControl === "airplay"
        receiverName: root.airplayReceiverName
        fps: root.airplayFps
        volumePercent: root.airplayVolumePercent
        blocked: airDropControl.active
        onReceiverNameChanged: root.airplayReceiverName = receiverName
        onHideRequested: root.controlRequested("close-airplay")
        onShowRequested: root.controlRequested("airplay")
    }
    property alias airdrop: airDropControl
    AirDropControl {
        id: airDropControl
        enabled: root.settingsReady && root.ccEnabled
        airplayBusy: mirroring.sending || mirroring.receiving || mirroring.connecting
        receiverName: root.airdropReceiverName
        onReceiverNameChanged: root.airdropReceiverName = receiverName
        onShowRequested: root.controlRequested("close-cc")
    }
    AirDropWindow {
        id: airDropWindow; controller: airDropControl
        foreground: root.darkMode ? "#f5f5f7" : "#1d1d1f"; accent: root.accent; family: root.fontFamily
    }
    IpcHandler {
        target: "airdrop"
        function open(): void { root.controlRequested("airdrop"); }
        function refresh(): void { airDropControl.refresh(); }
        function stop(): void { airDropControl.stop(); }
        function state(): string { return JSON.stringify(airDropControl.state); }
        function files(paths: string): void { try { airDropControl.setFiles(JSON.parse(paths)); } catch (error) { airDropControl.error = "Choose local files."; } }
    }
    IpcHandler {
        target: "mirroring"
        function open(): void { root.controlRequested("airplay"); }
        function stop(): void { root.mirroring.disconnect(); root.mirroring.setReceiver(false); }
        function receive(enabled: bool): void { root.mirroring.setReceiver(enabled); }
        function state(): string {
            return JSON.stringify({senderAvailable: root.mirroring.senderAvailable, receiverAvailable: root.mirroring.receiverAvailable,
                sender: root.mirroring.senderState, receiver: root.mirroring.receiverState, devices: root.mirroring.devices,
                streams: root.mirroring.streams, receiverName: root.mirroring.advertisedName, awaitingCode: root.mirroring.pending !== null,
                receiverAwaitingCode: root.mirroring.receiverPin !== "", senderError: root.mirroring.senderError, receiverError: root.mirroring.receiverError});
        }
    }
    function pickColor() { Quickshell.execDetached(["sh", decodeURIComponent(Qt.resolvedUrl("niri-color.sh").toString().replace(/^file:\/\//, ""))]); }
    Process {
        id: fileSearchProc
        command: ["sh", "-c", "find \"$HOME\" -type f -iname \"*$1*\" -not -path '*/.cache/*' -not -path '*/.local/share/Trash/*' 2>/dev/null | head -n 8", "sh", root.fileQuery]
        stdout: StdioCollector { onStreamFinished: {
            var a=text.trim().split("\n").filter(function(x){return x!=="";});
            if (root.fileSearchFor === root.fileQuery) { root.fileHits=a; root.fileSearchPending=false; }
            else fileDebounce.restart();
        } }
        onExited: if (root.fileSearchFor !== root.fileQuery) fileDebounce.restart()
    }
    Timer { id: fileDebounce; interval: 260; onTriggered: {
        if (root.fileQuery.length > 0 && !fileSearchProc.running) { root.fileSearchFor=root.fileQuery; root.fileSearchPending=true; fileSearchProc.running=true; }
    } }
    function updateFileSearch(q) { fileQuery=q; fileHits=[]; fileSearchPending=true; fileDebounce.restart(); }

    // Persist deadlines, never countdown ticks. Restore before enabling idle backends.
    property bool modesMigrated: false
    property var modeState: ({focus: {mode: "off"}, awake: {mode: "off"}})
    property alias timedModes: modes
    property bool dnd: false
    property bool keepAwake: false
    property bool nightOn: false
    property bool nightDesired: false
    property alias nightShift: nightControl
    onNotifDndChanged: if (settingsReady && modes.restored && notifDnd !== modes.active("focus")) modes.set("focus", notifDnd ? "manual" : "off")
    onDndChanged: if (settingsReady && modes.restored && dnd !== modes.active("focus")) modes.set("focus", dnd ? "manual" : "off")
    onKeepAwakeChanged: if (settingsReady && modes.restored && keepAwake !== modes.active("awake")) modes.set("awake", keepAwake ? "manual" : "off")
    function toggleDnd() { modes.toggle("focus"); }
    function toggleNightShift() { nightDesired = !nightDesired; }
    TimedModes {
        id: modes
        enabled: root.settingsReady
        saved: root.modeState
        onPersist: value => root.modeState = value
        onValuesChanged: {
            root.dnd = !!active("focus"); root.notifDnd = root.dnd;
            root.keepAwake = !!active("awake");
        }
        onRestoredChanged: if (restored) { root.dnd = !!active("focus"); root.notifDnd = root.dnd; root.keepAwake = !!active("awake"); }
    }
    NightShiftControl {
        id: nightControl; active: root.settingsReady; desired: root.nightDesired; temperature: root.nightTemp
        onEnabledChanged: root.nightOn = enabled
    }

    // ═════════════ MENUS ═════════════
    function mi(label, shortcut, run) { return { kind: "item", label: label, shortcut: shortcut || "", run: run }; }
    function mc(label, run) { return { kind: "item", label: label, shortcut: "", run: run, confirm: true }; }
    function msep() { return { kind: "sep" }; }
    function disp(args) { return function () { Niri.action(args); }; }
    function keys(mods, key) {
        return function () {
            var args = ["wtype"];
            mods.forEach(function(m) { args.push("-M", m); });
            args.push("-k", key);
            mods.slice().reverse().forEach(function(m) { args.push("-m", m); });
            Quickshell.execDetached(args);
        };
    }
    function mchk(label, shortcut, checked, run) { return { kind: "item", label: label, shortcut: shortcut || "", run: run, checked: checked === true }; }
    function dis(item, off) { if (off) item.disabled = true; return item; }

    // what kind of app is focused, so the menus can offer the right shortcuts
    function appKind(id) {
        var c = (id || "").toLowerCase();
        function any(list) { for (var i = 0; i < list.length; i++) if (c.indexOf(list[i]) >= 0) return true; return false; }
        if (any(["kitty", "alacritty", "foot", "wezterm", "ghostty", "konsole", "terminal", "xterm", "urxvt", "terminator", "tilix", "ptyxis"])) return "terminal";
        if (c === "zen" || any(["firefox", "chromium", "chrome", "brave", "zen-browser", "zen_browser", "vivaldi", "librewolf", "floorp", "waterfox", "opera", "epiphany", "falkon", "helium", "thorium", "microsoft-edge", "qutebrowser"])) return "browser";
        if (any(["nautilus", "dolphin", "thunar", "nemo", "pcmanfm", "caja", "krusader"])) return "files";
        if (any(["code", "codium", "cursor", "dev.zed", "kate", "gedit", "sublime", "geany", "neovide", "emacs", "jetbrains", "pycharm", "intellij", "clion", "webstorm"])) return "editor";
        return "";
    }
    function shot(region) {      // "" = whole screen, "sel" = pick an area (frozen-screen picker), otherwise "x,y WxH"
        if (region === "sel") shotStart();
        else shotFinish(region, "");
    }
    function shotWindow(aw) {
        if (!aw || !aw.at || !aw.size) return;
        shot(Math.round(aw.at[0]) + "," + Math.round(aw.at[1]) + " " + Math.round(aw.size[0]) + "x" + Math.round(aw.size[1]));
    }
    function aboutActive(aw, n) {
        var l = [];
        if (aw) {
            l.push(Language.I18n.text("ui.t_7499de7d9988") + aw["class"]);
            l.push(Language.I18n.text("ui.t_606f2113571d") + aw.pid);
            if (aw.workspace) l.push(Language.I18n.text("ui.t_68256a37a790") + aw.workspace.name);
            if (aw.title) l.push(Language.I18n.text("ui.t_74ad422593f7") + aw.title);
        } else l.push(Language.I18n.text("ui.t_7499de7d9988") + activeAppId);
        Quickshell.execDetached(["notify-send", "-a", "macbar", "About " + n, l.join("\n")]);
    }
    function forceQuitActive(aw) {
        if (aw && aw.pid > 0) Quickshell.execDetached(["kill", "-9", String(Math.floor(aw.pid))]);
    }
    function helpFor(id, n) {    // man page if there is one, otherwise a web search
        var c = (id || "").toLowerCase().replace(/[^a-z0-9._+-]/g, "");
        if (c === "") return;
        var q = encodeURIComponent(n + " linux help").replace(/'/g, "%27");
        sh("if man -w " + c + " >/dev/null 2>&1; then " + terminal + " -e man " + c + "; else xdg-open 'https://duckduckgo.com/?q=" + q + "'; fi");
    }
    function emoji() {
        sh("for c in emote bemoji smile rofimoji wofi-emoji; do command -v $c >/dev/null 2>&1 && exec $c; done");
    }
    function quitActive() {
        var tls = Niri.toplevels.values;
        var key = Utilities.ownWindow(activeAppId, activeTl ? activeTl.title : "");
        for (var i = 0; i < tls.length; i++) if (Utilities.ownWindow(tls[i].appId, tls[i].title) === key) tls[i].close();
    }
    function launchActive() {
        var e = lookup(activeAppId);
        if (e) e.execute();
    }
    function search() {
        if (!spotlightEnabled && launcher === "") return;
        spotWant = "home";
        if (launcher !== "") sh(launcher);
        else spotRequest++;                       // every bar window listens and the focused screen opens Spotlight
    }
    function spotOpen(mode) { if (!spotlightEnabled) return; spotWant = mode; spotRequest++; }
    // qs -c MacShell-niri ipc call controlcenter toggle | open | close   (works with the menu bar switched off too)
    signal ccRequest(bool open)
    IpcHandler {
        target: "monitoring"
        function state(): string { return JSON.stringify({enabled: root.stats.enabled, open: root.activeControl === "stats", stale: root.stats.stale,
            interval: root.stats.interval, sample: root.stats.sample}); }
        function open(): void { root.showMonitoring(); }
        function close(): void { root.controlRequested("close-stats"); }
    }
    IpcHandler {
        target: "controlcenter"
        function toggle(): void { root.ccRequest(true); }
        function open(): void { root.ccRequest(true); }
        function close(): void { root.ccRequest(false); }
        function page(name: string): void {
            if (["cc", "wifi", "bt", "focus", "awake", "night", "vol", "stats", "battery", "airplay"].indexOf(name) >= 0)
                root.controlRequested(name);
            else if (name === "record" && !root.recorder.busy) {
                root.recorder.prepare(); root.controlRequested(name);
            }
        }
    }
    IpcHandler {
        target: "spotlight"
        function toggle(): void { root.search(); }
        function clipboard(): void { root.spotOpen("clip"); }
        function emoji(): void { root.spotOpen("emoji"); }
        function apps(): void { root.spotOpen("apps"); }
        function preview(path: string): void { root.openQuickLook(path); }
    }

    // ═════════════ CLIPBOARD HISTORY + EMOJI (Spotlight panels) ═════════════
    // History comes from cliphist; its `wl-paste --watch` watchers are started here (unless you already run them), and every
    // new entry also gets a timestamp in ~/.cache/macbar/clip-times so the list can say "Copied 4:11 pm".
    property string clipState: "unknown"      // unknown | ok | external | missing
    property var clipEntries: []              // newest first
    property bool clipLoading: false
    readonly property string clipDir: (Quickshell.env("XDG_CACHE_HOME") || Quickshell.env("HOME") + "/.cache") + "/macbar"
    // the system's default colour emoji font (asked from fontconfig); Noto Color Emoji until that answers
    property string emojiFont: "Noto Color Emoji"
    Process {
        running: true
        command: ["sh", "-c", "fc-match -f '%{family[0]}|%{color}' emoji 2>/dev/null"]
        stdout: StdioCollector {
            onStreamFinished: {
                var p = text.trim().split("|");
                if (p.length === 2 && p[0] !== "" && p[1].toLowerCase() === "true") root.emojiFont = p[0];
            }
        }
    }

    readonly property string clipStoreCmd: "cliphist store; id=$(cliphist list | head -n1 | cut -f1); t=\"${XDG_CACHE_HOME:-$HOME/.cache}/macbar/clip-times\"; "
        + "[ -n \"$id\" ] && [ \"$id\" != \"$(tail -n1 \"$t\" 2>/dev/null | cut -f1)\" ] && printf '%s\\t%s\\n' \"$id\" \"$(date +%s)\" >> \"$t\""
    readonly property string clipListCmd: [
        "if ! command -v cliphist >/dev/null 2>&1; then echo '@@MISSING@@'; exit 0; fi",
        "d=\"${XDG_CACHE_HOME:-$HOME/.cache}/macbar\"; mkdir -p \"$d/clip\"; t=\"$d/clip-times\"; touch \"$t\"",
        "l=$(mktemp); cliphist list 2>/dev/null | head -n 300 > \"$l\"",
        "awk -F'\\t' -v now=\"$(date +%s)\" 'FILENAME==ARGV[1]{s[$1]=1;next} !($1 in s){print $1\"\\t\"now}' \"$t\" \"$l\" >> \"$t\"",
        "tail -n 3000 \"$t\" > \"$t.tmp\" && mv \"$t.tmp\" \"$t\"",
        "awk -F'\\t' '$2 ~ /^\\[\\[ binary data/ {print $1}' \"$l\" | head -n 30 | while read -r id; do [ -s \"$d/clip/$id.img\" ] || cliphist decode \"$id\" > \"$d/clip/$id.img\" 2>/dev/null; done",
        "find \"$d/clip\" -type f -mtime +3 -delete 2>/dev/null",
        "cat \"$l\"; echo '@@TIMES@@'; cat \"$t\"; rm -f \"$l\""
    ].join("\n")

    function clipStart() {
        if (clipHistory && barEnabled && settingsReady) clipProbe.running = true;
        else { clipWatchText.running = false; clipWatchImg.running = false; }
    }
    onSettingsReadyChanged: { clipStart(); emojiEnsure(); }
    onClipHistoryChanged: clipStart()
    Process {
        id: clipProbe
        command: ["sh", "-c",
            "if ! command -v wl-paste >/dev/null 2>&1 || ! command -v cliphist >/dev/null 2>&1; then echo missing; exit 0; fi; "
            + "mkdir -p \"${XDG_CACHE_HOME:-$HOME/.cache}/macbar/clip\"; "
            // look at real wl-paste processes only (`pgrep -f` also matched this very shell, so it always answered "external"
            // and the watchers below never started)
            + "ext=0; for p in $(pgrep -x wl-paste 2>/dev/null); do "
            + "if tr '\\0' ' ' < /proc/$p/cmdline 2>/dev/null | grep -q cliphist; then ext=1; fi; done; "
            + "if [ $ext = 1 ]; then echo external; else echo ok; fi"]
        stdout: StdioCollector {
            onStreamFinished: {
                root.clipState = text.trim();
                if (root.clipState === "ok" && root.clipHistory && root.barEnabled && root.settingsReady) {
                    clipWatchText.running = true; clipWatchImg.running = true;
                }
            }
        }
    }
    Process { id: clipWatchText; command: ["wl-paste", "--type", "text", "--watch", "sh", "-c", root.clipStoreCmd, "sh"] }
    Process { id: clipWatchImg; command: ["wl-paste", "--type", "image", "--watch", "sh", "-c", root.clipStoreCmd, "sh"] }

    function clipRefresh() {
        // Dependencies may have been installed since the shell started.
        if (clipState === "missing" && clipHistory && barEnabled && settingsReady) clipStart();
        if (clipLoading) return;
        clipLoading = true;
        clipListProc.running = true;
    }
    Process {
        id: clipListProc
        command: ["sh", "-c", root.clipListCmd]
        stdout: StdioCollector {
            onStreamFinished: {
                root.clipLoading = false;
                if (text.indexOf("@@MISSING@@") === 0) { root.clipState = "missing"; root.clipEntries = []; return; }
                root.clipEntries = root.clipParse(text);
            }
        }
    }
    function clipWhen(ts) {
        if (!ts) return "";
        var d = new Date(ts * 1000), n = new Date();
        var tm = Language.I18n.formatDateTime(d, root.use24h ? "HH:mm" : "h:mm ap");
        var today = new Date(n.getFullYear(), n.getMonth(), n.getDate()).getTime();
        var day = new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
        if (day === today) return Language.I18n.text("ui.t_cb6ce564da41") + tm;
        if (day === today - 86400000) return Language.I18n.text("ui.t_0c5e35f293ec") + tm;
        return Language.I18n.text("ui.t_cb6ce564da41") + Language.I18n.formatDateTime(d, "d MMM") + ", " + tm;
    }
    function clipEntry(id, txt, ts) {
        var en = { id: id, text: txt, kind: "text", title: txt, label: Language.I18n.text("ui.t_71988c4d8e08"), host: "", thumb: "", color: "" };
        var m = /^\[\[ binary data ([\d.]+ \w+) (\w+) (\d+x\d+) \]\]$/.exec(txt);
        if (m) {
            en.kind = "image";
            en.title = "Image " + m[3].replace("x", "\u00D7");
            en.label = "Image \u2022 " + m[2].toUpperCase() + " \u2022 " + m[1];
            en.thumb = "file://" + clipDir + "/clip/" + id + ".img";
        } else if (/^(https?|ftp):\/\/\S+$/i.test(txt) || /^www\.\S+\.\S+$/i.test(txt)) {
            en.kind = "url";
            en.host = txt.replace(/^[a-z]+:\/\//i, "").split(/[\/?#]/)[0];
            en.label = "URL \u2022 " + en.host;
        } else if (/^#([0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$/i.test(txt)) {
            en.kind = "color";
            en.color = txt;
            en.label = "Color";
        }
        var w = clipWhen(ts);
        en.sub = en.label + (w !== "" ? " \u2022 " + w : "");
        return en;
    }
    function clipParse(out) {
        var parts = out.split("@@TIMES@@\n");
        var lines = parts[0].split("\n"), tl = (parts[1] || "").split("\n"), times = {}, res = [], i;
        for (i = 0; i < tl.length; i++) {
            var p = tl[i].split("\t");
            if (p.length >= 2) times[p[0]] = parseInt(p[1]);
        }
        for (i = 0; i < lines.length; i++) {
            var tab = lines[i].indexOf("\t");
            if (tab < 1) continue;
            var id = lines[i].substring(0, tab);
            res.push(clipEntry(id, lines[i].substring(tab + 1), times[id] || 0));
        }
        return res;
    }
    function clipRunner(en) { return function () { root.clipPick(en, undefined); }; }
    function clipFiltered(q) {
        q = (q || "").trim().toLowerCase();
        var src = clipEntries, out = [];
        for (var i = 0; i < src.length && out.length < 150; i++) {
            var en = src[i];
            if (q !== "" && en.text.toLowerCase().indexOf(q) < 0 && en.label.toLowerCase().indexOf(q) < 0) continue;
            var it = {};
            for (var k in en) it[k] = en[k];
            it.confirm = false;
            it.run = clipRunner(en);
            out.push(it);
        }
        return out;
    }
    function clipPick(en, paste) {
        var id = parseInt(en.id);
        if (isNaN(id)) return;
        sh("cliphist decode " + id + " | wl-copy");
        if (paste === undefined ? clipAutoPaste : paste) pasteSoon();
    }
    // a clipboard entry dropped on the desktop: open it (image → viewer, URL → browser, text → editor)
    function clipOpen(en) {
        var id = parseInt(en.id);
        if (isNaN(id)) return;
        if (en.kind === "url") { Quickshell.execDetached(["xdg-open", /^www\./i.test(en.text) ? "https://" + en.text : en.text]); return; }
        var ext = en.kind === "image" ? (/(png|jpe?g|webp|gif|bmp)/i.exec(en.label) || ["png"])[0].toLowerCase() : "txt";
        Quickshell.execDetached(["sh", "-c", 'd="${XDG_RUNTIME_DIR:-/tmp}/macshell-clip"; mkdir -p "$d"; f="$d/clip-$1.$2"; cliphist decode "$1" > "$f" && exec xdg-open "$f"',
                                 "sh", String(id), ext]);
    }
    function clipDelete(en) {
        if (!en) return;
        var id = parseInt(en.id);
        if (isNaN(id)) return;
        clipEntries = clipEntries.filter(function (x) { return x.id !== en.id; });
        sh("printf '%s\\t\\n' " + id + " | cliphist delete; rm -f \"${XDG_CACHE_HOME:-$HOME/.cache}/macbar/clip/" + id + ".img\"");
    }
    function clipClear() {
        clipEntries = [];
        sh("cliphist wipe; rm -f \"${XDG_CACHE_HOME:-$HOME/.cache}/macbar/clip-times\" \"${XDG_CACHE_HOME:-$HOME/.cache}/macbar/clip/\"*");
    }
    // paste into the app that had focus before Spotlight (terminals paste with Ctrl+Shift+V)
    property var pasteFn: null
    function pasteSoon() {
        pasteFn = appKind(activeAppId) === "terminal" ? keys(["ctrl", "shift"], "v") : keys(["ctrl"], "v");
        pasteTimer.restart();
    }
    Timer { id: pasteTimer; interval: 230; onTriggered: if (root.pasteFn) root.pasteFn() }

    // emoji: search by name / keyword, categories, recents
    // Data comes from the system's own Unicode files when they exist (emoji-test.txt = every emoji with its official name and
    // category, CLDR annotations = search keywords), so it always matches your installed emoji font. EmojiData.js is the fallback.
    property var emojiList: EmojiData.list
    property string emojiSource: "bundled"
    property bool emojiTried: false
    readonly property var emojiIndex: {
        var m = {}, L = root.emojiList;
        for (var i = 0; i < L.length; i++) m[L[i][0]] = L[i];
        return m;
    }
    function emojiEnsure() {
        if (emojiTried) return;
        emojiTried = true;
        emojiLoadProc.running = true;
    }
    readonly property string emojiLoadCmd: [
        "t=''; for f in /usr/share/unicode/emoji/emoji-test.txt /usr/share/unicode/ucd/emoji/emoji-test.txt /usr/share/unicode-emoji/emoji-test.txt /usr/local/share/unicode/emoji/emoji-test.txt \"$HOME/.local/share/unicode/emoji-test.txt\"; do [ -r \"$f\" ] && { t=\"$f\"; break; }; done",
        "[ -z \"$t\" ] && t=$(find /usr/share /usr/local/share -maxdepth 6 -name emoji-test.txt 2>/dev/null | head -n1)",
        "[ -z \"$t\" ] && { echo '@@NONE@@'; exit 0; }",
        "echo '@@TEST@@'; grep -E '^(# (sub)?group:|[0-9A-F])' \"$t\"",
        "echo '@@CLDR@@'",
        "for d in annotations annotationsDerived; do f=''; for b in /usr/share/unicode/cldr/common /usr/share/unicode-cldr/common /usr/share/cldr/common /usr/share/unicode/cldr; do [ -r \"$b/$d/en.xml\" ] && { f=\"$b/$d/en.xml\"; break; }; done",
        "  [ -z \"$f\" ] && f=$(find /usr/share /usr/local/share -maxdepth 7 -path \"*/$d/en.xml\" 2>/dev/null | head -n1)",
        "  [ -n \"$f\" ] && grep -h '<annotation ' \"$f\"; done; true"
    ].join("\n")
    Process {
        id: emojiLoadProc
        command: ["sh", "-c", root.emojiLoadCmd]
        stdout: StdioCollector { onStreamFinished: root.emojiLoad(text) }
    }
    function emojiLoad(out) {
        var iT = out.indexOf("@@TEST@@\n"), iC = out.indexOf("@@CLDR@@\n");
        if (iT < 0 || iC < iT) return;                                  // no emoji-test.txt on this system: keep EmojiData.js
        var testTxt = out.substring(iT + 9, iC), cldrTxt = out.substring(iC + 9), m, i;
        function unesc(x) { return x.replace(/&quot;/g, "\"").replace(/&apos;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&"); }
        var kw = {}, re = /<annotation cp="([^"]+)"( type="tts")?>([^<]*)<\/annotation>/g;
        while ((m = re.exec(cldrTxt)) !== null) {
            if (m[2]) continue;
            var key = m[1].replace(/\uFE0F/g, "");
            kw[key] = (kw[key] ? kw[key] + " | " : "") + unesc(m[3]);
        }
        var cats = { "Smileys & Emotion": 0, "People & Body": 1, "Animals & Nature": 2, "Food & Drink": 3, "Travel & Places": 4,
                     "Activities": 5, "Objects": 6, "Symbols": 7, "Flags": 8 };
        var cat = -1, list = [], lines = testTxt.split("\n");
        for (i = 0; i < lines.length; i++) {
            var ln = lines[i];
            if (ln.charAt(0) === "#") {
                m = /^# group: (.+)$/.exec(ln);
                if (m) cat = cats[m[1].trim()] !== undefined ? cats[m[1].trim()] : -1;      // "Component" (skin tones, hair) -> skipped
                continue;
            }
            if (cat < 0) continue;
            m = /^[0-9A-F ]+;\s*(\S+)\s*#\s*(\S+)\s+E\d+(?:\.\d+)?\s+(.+)$/.exec(ln);
            if (!m || m[1] !== "fully-qualified") continue;
            var name = m[3].trim();
            if (name.indexOf("skin tone") >= 0) continue;                  // tone variants would triple the grid; the base emoji is kept
            var extra = (kw[m[2].replace(/\uFE0F/g, "")] || "").replace(/ \| /g, " ");
            list.push([m[2], name, extra, cat, (name + " " + extra).toLowerCase()]);
        }
        if (list.length < 800) return;                                  // looks wrong, keep the bundled list
        root.emojiList = list;
        root.emojiSource = "system";
    }
    function emojiItems(q, cat) {
        var L = root.emojiList, out = [], i;
        q = (q || "").trim().toLowerCase();
        if (q !== "") {
            var hits = [];
            for (i = 0; i < L.length; i++) {
                var translatedName = Language.I18n.emojiName(L[i][0], L[i][1]).toLowerCase();
                var p = (L[i][4] + " " + translatedName + " " + Language.I18n.emojiKeywords(L[i][0])).toLowerCase().indexOf(q);
                if (p < 0) continue;
                var nm = translatedName;
                // exact name, name starts with it, exact keyword (e.g. "smile" -> grinning face), a word of the name, anything else
                hits.push([nm === q ? 0 : (nm.indexOf(q) === 0 ? 1 : ((" " + L[i][2] + " ").indexOf(" " + q + " ") >= 0 ? 2
                           : (nm.indexOf(" " + q) >= 0 ? 3 : (p === 0 ? 4 : 5)))), i]);
            }
            hits.sort(function (a, b) { return a[0] - b[0] || a[1] - b[1]; });
            for (i = 0; i < hits.length && i < 240; i++) out.push(L[hits[i][1]]);
            return out;
        }
        if (cat === 0) {
            for (i = 0; i < emojiRecent.length; i++) if (emojiIndex[emojiRecent[i]]) out.push(emojiIndex[emojiRecent[i]]);
            return out;
        }
        for (i = 0; i < L.length; i++) if (L[i][3] === cat - 1) out.push(L[i]);
        return out;
    }
    function emojiPick(en) {
        if (!en) return;
        var r = [en[0]];
        for (var i = 0; i < emojiRecent.length && r.length < 24; i++) if (emojiRecent[i] !== en[0]) r.push(emojiRecent[i]);
        emojiRecent = r;
        Quickshell.execDetached(["sh", "-c", "printf %s \"$1\" | wl-copy", "sh", en[0]]);
        if (clipAutoPaste) pasteSoon();
    }

    // ── applications for Spotlight ──
    function iconSrc(name) {
        var fb = Quickshell.iconPath("application-x-executable", true);
        if (!name) return fb;
        if (name.indexOf("file:") === 0 || name.indexOf("qrc:") === 0) return name;
        if (name.indexOf("/") === 0) return "file://" + name;
        var p = Quickshell.iconPath(name, true);
        return p !== "" ? p : fb;
    }
    readonly property var appList: {
        var vals = DesktopEntries.applications.values, out = Utilities.entries(key => { if (root.hub && root.hub.openUtility) root.hub.openUtility(key); }, value => Language.I18n.legacy(value), Language.I18n.activeLanguage)
            .filter(app => app.key !== "clock" || !root.hub || !root.hub.clock || root.hub.clock.appEnabled);
        for (var i = 0; i < vals.length; i++) if (!vals[i].noDisplay && !Utilities.find(vals[i].id)) out.push(vals[i]);
        out.sort(function (a, b) { return a.name.localeCompare(b.name); });
        return out;
    }
    readonly property var appCats: [
        ["Game", "Games"], ["Office", "Productivity & Finance"], ["Finance", "Productivity & Finance"],
        ["Network", "Internet & Social"], ["WebBrowser", "Internet & Social"], ["Development", "Developer Tools"],
        ["Graphics", "Graphics & Design"], ["AudioVideo", "Music & Video"], ["Audio", "Music & Video"],
        ["Video", "Music & Video"], ["Education", "Education & Science"], ["Science", "Education & Science"],
        ["Settings", "System"], ["System", "System"], ["Utility", "Utilities"]
    ]
    readonly property var catOrder: ["Games", "Productivity & Finance", "Internet & Social", "Developer Tools",
                                     "Graphics & Design", "Music & Video", "Education & Science", "Utilities", "System"]
    function appCategory(e) {
        var c = e.categories || [];
        for (var i = 0; i < appCats.length; i++)
            for (var j = 0; j < c.length; j++)
                if (c[j] === appCats[i][0]) return appCats[i][1];
        return "Utilities";
    }
    readonly property var appSections: {
        var list = appList, usage = appUsage, i, j;
        var used = list.filter(function (e) { return (usage[e.id] || 0) > 0; });
        used.sort(function (a, b) { return (usage[b.id] || 0) - (usage[a.id] || 0); });
        var sug = used.slice(0, 10);
        for (i = 0; i < list.length && sug.length < 5; i++) {
            var dup = false;
            for (j = 0; j < sug.length; j++) if (sug[j].id === list[i].id) { dup = true; break; }
            if (!dup) sug.push(list[i]);
        }
        var map = {};
        for (i = 0; i < list.length; i++) {
            var cat = appCategory(list[i]);
            if (!map[cat]) map[cat] = [];
            map[cat].push(list[i]);
        }
        var secs = [{ name: Language.I18n.text("ui.t_16c1d601fc66"), apps: sug }];
        for (i = 0; i < catOrder.length; i++) if (map[catOrder[i]]) secs.push({ id: catOrder[i], name: Language.I18n.legacy(catOrder[i]), apps: map[catOrder[i]] });
        return secs;
    }
    function searchApps(q) {
        q = (q || "").trim().toLowerCase();
        if (q === "") return [];
        var list = appList, hits = [];
        for (var i = 0; i < list.length; i++) {
            var e = list[i], n = e.name.toLowerCase(), sc = 0;
            if (n === q) sc = 100;
            else if (n.indexOf(q) === 0) sc = 80;
            else if (n.indexOf(" " + q) >= 0) sc = 60;
            else if (n.indexOf(q) >= 0) sc = 40;
            else if ((e.genericName || "").toLowerCase().indexOf(q) >= 0) sc = 25;
            else if ((e.comment || "").toLowerCase().indexOf(q) >= 0) sc = 10;
            else {
                var kw = e.keywords || [];
                for (var k = 0; k < kw.length; k++) if (String(kw[k]).toLowerCase().indexOf(q) >= 0) { sc = 15; break; }
            }
            if (sc > 0) hits.push({ e: e, s: sc + Math.min(appUsage[e.id] || 0, 20) });
        }
        hits.sort(function (a, b) { return b.s - a.s; });
        return hits.map(function (h) { return h.e; });
    }
    function appSearchSection(q) {
        var r = searchApps(q);
        return r.length > 0 ? [{ name: Language.I18n.text("ui.t_effd40c768bb"), apps: r }] : [];
    }
    function launchApp(e) {
        var u = {};
        for (var k in appUsage) u[k] = appUsage[k];
        u[e.id] = (u[e.id] || 0) + 1;
        appUsage = u;
        saveTimer.restart();
        e.execute();
    }
    function appRunner(e) { return function () { launchApp(e); }; }
    function appItems(q, limit) {
        var r = searchApps(q), out = [];
        for (var i = 0; i < r.length && i < limit; i++)
            out.push({ title: r[i].name, sub: r[i].genericName || Language.I18n.text("ui.t_e7ad522ea327"), icon: iconSrc(r[i].icon),
                       glyph: "", kind: "app", appId: r[i].id, confirm: false, run: appRunner(r[i]) });
        return out;
    }
    function actionItems(q) {
        var all = [
            { title: Language.I18n.text("ui.t_91a007b58b9d"), glyph: "lock", run: function () { Quickshell.execDetached(["sh", (Quickshell.env("MACSHELL_LOCK_HELPER") || Qt.resolvedUrl("../MacLock/lock-via-ipc.sh").toString().replace(/^file:\/\//, ""))]); } },
            { title: Language.I18n.text("ui.t_d466bcf52eb6"), glyph: "moon", run: function () { sh("systemctl suspend"); } },
            { title: Language.I18n.text("ui.t_85c35c367d93"), keywords: "settings system preferences настройка настройки системные параметры", glyph: "gear", run: function () { openSettings(); } },
            { title: Language.I18n.text("ui.t_d57d48b71020"), glyph: "logout", confirm: true, run: function () { root.logOut(); } },
            { title: Language.I18n.text("ui.t_6b983a81e5e8"), glyph: "restart", confirm: true, run: function () { sh("systemctl reboot"); } },
            { title: Language.I18n.text("ui.t_3e45a33d2260"), glyph: "power", confirm: true, run: function () { sh("systemctl poweroff"); } }
        ];
        var s = (q || "").trim().toLowerCase(), out = [];
        for (var i = 0; i < all.length; i++) {
            if (s !== "" && (all[i].title + " " + (all[i].keywords || "")).toLowerCase().indexOf(s) < 0) continue;
            out.push({ title: all[i].title, sub: Language.I18n.text("ui.t_64cff1319d2f"), icon: "", glyph: all[i].glyph,
                       kind: "action", confirm: all[i].confirm === true, run: all[i].run });
        }
        return out;
    }
    function settingsItems(q) {
        if (!hub || !hub.dock || !hub.dock.settingsEnabled) return [];
        var found = SettingsSearch.match(hub.dock.settingsSearchPanes || [], q), out = [];
        for (var i = 0; i < found.length; i++) {
            (function (id, name) {
                out.push({ title: name, sub: Language.I18n.text("ui.t_85c35c367d93"), glyph: "gear",
                           kind: "settings", pane: id, run: function () { root.openSettings(id); } });
            })(found[i].id, found[i].name);
        }
        return out;
    }
    function calcValue(expr) {
        var t=String(expr || "").replace(/[xX×]/g, "*").replace(/÷/g, "/");
        if (!/^[0-9+\-*/%.()\s]+$/.test(t) || !/[0-9]/.test(t)) return null;
        var i=0;
        function ws(){ while(i<t.length && /\s/.test(t[i])) i++; }
        function atom(){ ws(); if(t[i]==="+"){i++;return atom();} if(t[i]==="-"){i++;return -atom();} if(t[i]==="("){i++;var v=sum();ws();if(t[i]!==")")throw 0;i++;return v;} var m=t.substring(i).match(/^(?:\d+(?:\.\d*)?|\.\d+)/);if(!m)throw 0;i+=m[0].length;return Number(m[0]); }
        function term(){ var v=atom(); for(;;){ws();var op=t[i];if(op!=="*"&&op!=="/"&&op!=="%")break;i++;var r=atom();if((op==="/"||op==="%")&&r===0)throw 0;v=op==="*"?v*r:(op==="/"?v/r:v%r);}return v; }
        function sum(){var v=term();for(;;){ws();var op=t[i];if(op!=="+"&&op!=="-")break;i++;var r=term();v=op==="+"?v+r:v-r;}return v;}
        try { var v=sum(); ws(); return i===t.length && isFinite(v) ? v : null; } catch(e){ return null; }
    }
    function conversion(q) {
        var m=(q||"").trim().match(/^(-?\d+(?:\.\d+)?)\s*([a-z°]+)\s+(?:to|in)\s+([a-z°]+)$/i); if(!m)return null;
        var val=Number(m[1]), a=m[2].toLowerCase(), b=m[3].toLowerCase();
        var units={mm:["len",.001],cm:["len",.01],m:["len",1],km:["len",1000],in:["len",.0254],ft:["len",.3048],mi:["len",1609.344],g:["mass",.001],kg:["mass",1],lb:["mass",.45359237],oz:["mass",.0283495],ml:["vol",.001],l:["vol",1],gal:["vol",3.78541],ms:["time",.001],s:["time",1],min:["time",60],h:["time",3600],c:["temp",1],"°c":["temp",1],f:["temp",1],"°f":["temp",1]};
        if(!units[a]||!units[b]||units[a][0]!==units[b][0])return null;
        var result;
        if(units[a][0]==="temp") result=(a==="f"||a==="°f")?(val-32)*5/9:val, result=(b==="f"||b==="°f")?result*9/5+32:result;
        else result=val*units[a][1]/units[b][1];
        return {title:Number(result.toPrecision(7))+" "+b,sub:"Unit conversion",glyph:"link",run:function(){Quickshell.execDetached(["wl-copy",String(result)]);}};
    }
    function windowItems(q) {
        var out=[], s=(q||"").trim().toLowerCase(); if(!s)return out;
        var ts=Niri.toplevels.values;
        for(var i=0;i<ts.length&&out.length<4;i++){
            var t=ts[i], o=t.lastIpcObject||{}, title=String(o.title||t.title||""), cls=String(o["class"]||t.appId||""), app=root.lookup(cls), label=title||app&&app.name||cls;
            if((label+" "+cls+" "+(app?app.name:" ")).toLowerCase().indexOf(s)<0)continue;
            var addr=String(t.id);
            (function(win,addr,workspace,cl,name,icon){out.push({title:name,sub:Language.I18n.text("ui.t_d3aa9a25b08d"),icon:icon||"",glyph:"layers",kind:"window",run:function(){root.swPending={id:win.id};swFocusTimer.restart();}});})(t,addr,o.workspace&&o.workspace.id>0?o.workspace.id:0,cls,label,app?root.iconSrc(app.icon):"");
        }
        return out;
    }
    function fileItems(q) {
        var out=[]; for(var i=0;i<fileHits.length&&out.length<5;i++){var path=fileHits[i];out.push({title:path.substring(path.lastIndexOf("/")+1)||path,sub:path,glyph:"folder",kind:"file",path:path,run:(function(p){return function(){root.openLocalPath(p);};})(path)});} return out;
    }
    function copyText(value) {
        Quickshell.execDetached(["sh", "-c", "printf %s \"$1\" | wl-copy", "sh", String(value)]);
    }
    function openLocalPath(path) {
        if (!SettingsSearch.isLocalPath(path)) return;
        Quickshell.execDetached(["xdg-open", path]);
    }
    function revealLocalPath(path) {
        var dir = SettingsSearch.parentDir(path);
        if (!dir) return;
        Quickshell.execDetached(["xdg-open", dir]);
    }
    function openQuickLook(path) {
        var local = QuickLook.localPath(path);
        if (!local || !hub || !hub.quickLook) return;
        hub.quickLook.open(local);
    }
    function spotlightActionTitle(id, row, item) {
        if (id === "pin") return (row && row.pinned) ? Language.I18n.text("ui.t_0cbc564f2355") : Language.I18n.text("ui.t_eb625dddc8f0");
        if (id === "reveal") return Language.I18n.text("spotlight.show_in_folder");
        if (id === "copyPath") return Language.I18n.text("spotlight.copy_path");
        if (id === "preview") return Language.I18n.text("spotlight.quick_look");
        if (id === "info") return Language.I18n.text("appmenu.get_info");
        if (id === "remove") return Language.I18n.text("appmenu.uninstall");
        if (id === "reinstall") return Language.I18n.text("appmenu.reinstall");
        if (id === "update") {
            var origin = item && hub && hub.desktopSource ? ((hub.desktopSource.sourceOf(item.appId) || {}).origin || "") : "";
            return origin === "pacman" ? Language.I18n.text("appmenu.update_system") : Language.I18n.text("appmenu.update");
        }
        return Language.I18n.text("ui.t_ed077f3d8125");
    }
    function spotlightActionReason(id, reason) {
        if (!reason) return "";
        if (reason === "pending") return Language.I18n.text("appmenu.reason_pending");
        if (reason === "ambiguous") return Language.I18n.text("appmenu.reason_ambiguous");
        if (reason === "builtin") return Language.I18n.text("appmenu.reason_builtin");
        if (reason === "local") return Language.I18n.text("appmenu.reason_local");
        if (reason === "unofficial") return Language.I18n.text("appmenu.reason_unofficial");
        if (reason === "confirm") return Language.I18n.text("appmenu.reason_confirm");
        if (reason === "busy") return Language.I18n.text("appmenu.apply_busy");
        if (reason === "unowned") return Language.I18n.text("appmenu.reason_unowned");
        if (reason === "missing") return Language.I18n.text("appmenu.reason_missing");
        if (reason === "system-update") return Language.I18n.text("appmenu.reason_system_update");
        if (id === "preview") return Language.I18n.text("spotlight.quick_look_unavailable");
        if (id === "copyPath") return Language.I18n.text("spotlight.copy_unavailable");
        return Language.I18n.text("spotlight.reveal_unavailable");
    }
    function spotlightActionGlyph(id, item) {
        if (id === "reveal") return "folder";
        if (id === "copyPath") return "link";
        if (id === "preview" || id === "info") return "search";
        if (id === "pin") return "appstore";
        if (id === "remove") return "logout";
        if (id === "reinstall") return "restart";
        if (id === "update") return "restart";
        return (item && item.glyph) ? item.glyph : "appstore";
    }
    function spotlightActions(item) {
        void root.desktopSourceTick;
        var rows, out = [];
        if (item && item.kind === "app") {
            var source = hub && hub.desktopSource ? hub.desktopSource.sourceOf(item.appId) : null;
            var pinned = hub && hub.dock ? hub.dock.isPinned(item.appId) : false;
            var applying = !!(hub && hub.desktopSource && hub.desktopSource.applying);
            rows = AppMenu.actions({ pinned: pinned, hasEntry: true, source: source, applying: applying });
        } else {
            rows = SettingsSearch.describe(item && item.kind, item);
        }
        for (var i = 0; i < rows.length; i++) {
            (function (row) {
                if (row.id === "sep") return;
                var reason = row.enabled ? (row.summary || "") : root.spotlightActionReason(row.id, row.reason);
                var confirmLabel = "";
                if (row.confirm === true) {
                    var name = (item && item.title) || "";
                    var label = row.summary || name;
                    if (row.confirmKind === "update_system") confirmLabel = Language.I18n.text("appmenu.confirm_update_system", {name: name || label});
                    else if (row.confirmKind === "reinstall") confirmLabel = Language.I18n.text("appmenu.confirm_reinstall", {name: label});
                    else if (row.confirmKind === "update") confirmLabel = Language.I18n.text("appmenu.confirm_update", {name: label});
                    else if (row.confirmKind === "remove") confirmLabel = Language.I18n.text("appmenu.confirm_remove", {name: label});
                }
                out.push({
                    title: root.spotlightActionTitle(row.id, row, item),
                    sub: reason,
                    glyph: root.spotlightActionGlyph(row.id, item),
                    kind: "action",
                    enabled: row.enabled,
                    close: row.close,
                    confirm: row.confirm === true,
                    confirmLabel: confirmLabel,
                    run: function () {
                        if (!row.enabled) return;
                        if (row.id === "open" && item && item.run) item.run();
                        else if (row.id === "reveal" && item && item.kind === "app" && hub && hub.desktopSource) hub.desktopSource.reveal(hub.desktopSource.sourceOf(item.appId));
                        else if (row.id === "reveal") root.revealLocalPath(item.path);
                        else if (row.id === "copyPath") root.copyText(item.path);
                        else if (row.id === "preview") root.openQuickLook(item.path);
                        else if (row.id === "pin" && item && hub && hub.dock) hub.dock.togglePinById(item.appId);
                        else if (row.id === "info" && item && hub && hub.desktopSource) hub.desktopSource.showInfo(item.title, hub.desktopSource.sourceOf(item.appId));
                        else if ((row.id === "remove" || row.id === "reinstall" || row.id === "update") && item && hub && hub.desktopSource)
                            hub.desktopSource.apply(item.appId, row.id, source);
                    }
                });
            })(rows[i]);
        }
        return out;
    }
    function homeItems(q) {
        var out = [], s = (q || "").trim().toLowerCase();
        if (s.indexOf("file ") === 0 || s.indexOf("find ") === 0) {
            var fq=s.replace(/^(file|find)\s+/,"").trim(); if(fq!=="" && fileQuery!==fq) updateFileSearch(fq);
            out=fileItems(fq); if(out.length===0) out.push({title:fileSearchPending?Language.I18n.text("ui.t_0d9498215681"):Language.I18n.text("ui.t_7eaa329a4009"),sub:Language.I18n.text("ui.t_abc7e9892806"),glyph:"folder",run:function(){}});
            return out;
        }
        if(s.length>0) out=appItems(q,4);
        var cv=conversion(s); if(cv) { cv.kind = "conversion"; out.unshift(cv); }
        else { var expr=s.replace(/^=\s*/,""); var v=calcValue(expr); if(v!==null && (s.charAt(0)==="=" || /[+*/%xX×÷()]/.test(s))) out.unshift({title:String(Number(v.toPrecision(10))),sub:"Calculator · Return to copy",glyph:"search",kind:"calc",run:function(){Quickshell.execDetached(["wl-copy",String(v)]);}}); }
        SettingsSearch.appendGroup(out, settingsItems(q), 8, 4);
        SettingsSearch.appendGroup(out, actionItems(q), 8, 4);
        SettingsSearch.appendGroup(out, windowItems(q), 8, 4);
        if(s.length>0 && out.length<8) out.push({title:Language.I18n.text("ui.t_e4f015d65bd9")+q.trim()+"”",sub:"Web Search · Return to open",glyph:"search",kind:"web",run:function(){Quickshell.execDetached(["xdg-open","https://search.brave.com/search?q="+encodeURIComponent(q.trim())]);}});
        out = out.slice(0,8);
        if (hub && hub.desktopSource) {
            for (var p = 0; p < out.length; p++) {
                if (out[p].kind === "app" && out[p].appId) hub.desktopSource.request(out[p].appId);
            }
        }
        return out;
    }

    function menuModelFor(name) {
        var m = [], i;
        if (name === "apple") {
            m.push(mi(Language.I18n.text("ui.t_ad469209b12b"), "", function () { sh(terminal + " -e sh -c 'fastfetch || neofetch; echo; read -p \"Press Enter\" _'"); }));
            m.push(msep());
            m.push(mi(Language.I18n.text("ui.t_85c35c367d93"), "", function () { root.openSettings(); }));
            m.push(msep());
            m.push(mi("Lock Screen", "", function () { Quickshell.execDetached(["sh", (Quickshell.env("MACSHELL_LOCK_HELPER") || Qt.resolvedUrl("../MacLock/lock-via-ipc.sh").toString().replace(/^file:\/\//, ""))]); }));
            m.push(mi(Language.I18n.text("ui.t_d466bcf52eb6"), "", function () { sh("systemctl suspend"); }));
            m.push(msep());
            m.push(mc(Language.I18n.text("ui.t_2c58de95b0c9"), function () { sh("systemctl reboot"); }));
            m.push(mc(Language.I18n.text("ui.t_6f9f1fa0f12b"), function () { sh("systemctl poweroff"); }));
            m.push(msep());
            m.push(mc(Language.I18n.text("ui.t_6011f9d3572d"), function () { root.logOut(); }));
        } else {
            var id = activeAppId.toLowerCase(), kind = appKind(id), has = activeAppId !== "";
            var aw = (has && activeWin && String(activeWin["class"]).toLowerCase() === id) ? activeWin : null;
            var term = kind === "terminal", browser = kind === "browser", files = kind === "files", editor = kind === "editor";
            var floating = aw ? aw.floating === true : false, fsMode = aw ? Number(aw.fullscreen) : 0;
            var n = appName;

            if (name === "app") {
                if (!has) {
                    m.push(mi(Language.I18n.text("ui.t_981ace960b9e"), "", function () { sh(terminal); }));
                    m.push(mi(Language.I18n.text("ui.t_4b725923d942"), "", function () { sh(filesCmd); }));
                    m.push(msep());
                    m.push(mi(Language.I18n.text("ui.t_7336265a0467"), "", function () { root.search(); }));
                } else {
                    m.push(mi(Language.I18n.text("ui.t_c381a5010d7e") + n, "", function () { root.aboutActive(aw, n); }));
                    if (editor || files) {
                        m.push(msep());
                        m.push(mi(Language.I18n.text("ui.t_67102244a667"), "Ctrl+,", keys(["ctrl"], "comma")));
                    }
                    m.push(msep());
                    m.push(mi(Language.I18n.text("ui.t_aa760a5c3844") + n, "", function () { Niri.hideActive(); }));
                    m.push(mi(Language.I18n.text("ui.t_db118b1bcd22"), "", function () { Niri.showHidden(); }));
                    m.push(msep());
                    m.push(mi(Language.I18n.text("ui.t_259b35c42b89") + n, "Ctrl+Q", function () { root.quitActive(); }));
                    m.push(mc(Language.I18n.text("ui.t_189a41f12257") + n, function () { root.forceQuitActive(aw); }));
                }
            } else if (name === "file") {
                if (!has) {
                    m.push(mi(Language.I18n.text("ui.t_981ace960b9e"), "", function () { sh(terminal); }));
                    m.push(mi(Language.I18n.text("ui.t_748921aaebe0"), "", function () { sh(filesCmd); }));
                } else {
                    m.push(mi(Language.I18n.text("ui.t_7469c2f6ff3a"), "", function () { root.launchActive(); }));
                    if (browser) {
                        var ff = /firefox|librewolf|floorp|zen|waterfox/.test(id);
                        m.push(mi(Language.I18n.text("ui.t_f33668d1bf44"), ff ? "Ctrl+Shift+P" : "Ctrl+Shift+N", keys(["ctrl", "shift"], ff ? "p" : "n")));
                    }
                    if (browser || files) m.push(mi(Language.I18n.text("ui.t_b2f8fd639208"), "Ctrl+T", keys(["ctrl"], "t")));
                    if (term) m.push(mi(Language.I18n.text("ui.t_b2f8fd639208"), "Ctrl+Shift+T", keys(["ctrl", "shift"], "t")));
                    if (browser) m.push(mi(Language.I18n.text("ui.t_c5a521a215c8"), "Ctrl+Shift+T", keys(["ctrl", "shift"], "t")));
                    if (!term && !files) m.push(mi(Language.I18n.text("ui.t_1f1d592bdd1a"), "Ctrl+O", keys(["ctrl"], "o")));
                    if (!term && !files) {
                        m.push(msep());
                        m.push(mi(browser ? Language.I18n.text("ui.t_1acb00a7f24b") : Language.I18n.text("ui.t_1509f561f241"), "Ctrl+S", keys(["ctrl"], "s")));
                        if (!browser) m.push(mi(Language.I18n.text("ui.t_a4b76af59533"), "Ctrl+Shift+S", keys(["ctrl", "shift"], "s")));
                        m.push(mi(Language.I18n.text("ui.t_07c371255954"), "Ctrl+P", keys(["ctrl"], "p")));
                    }
                    m.push(msep());
                    if (browser || files || editor) m.push(mi(Language.I18n.text("ui.t_f271892dc1c3"), "Ctrl+W", keys(["ctrl"], "w")));
                    if (term) m.push(mi(Language.I18n.text("ui.t_f271892dc1c3"), "Ctrl+Shift+W", keys(["ctrl", "shift"], "w")));
                    m.push(mi(Language.I18n.text("ui.t_32fd144c1f4b"), "", disp(["close-window"])));
                }
                m.push(msep());
                if (aw) m.push(mi(Language.I18n.text("ui.t_150b38e88657"), "", function () { root.shotWindow(aw); }));
                m.push(mi(Language.I18n.text("ui.t_7f9dcc5cbf8b"), "", function () { root.shot("sel"); }));
                m.push(mi(Language.I18n.text("ui.t_dbdc217e6204"), "", function () { root.shot(""); }));
                m.push(mi(root.recording ? Language.I18n.text("ui.t_6b5e333bf3be") : Language.I18n.text("ui.t_9030a512d0f3"), "", function () { root.toggleRecording(); }));
                m.push(mi(Language.I18n.text("ui.t_9b78ab17c13f"), "", function () { root.pickColor(); }));
            } else if (name === "edit") {
                if (has && term) {
                    m.push(mi(Language.I18n.text("ui.t_e21f935f11d7"), "Ctrl+Shift+C", keys(["ctrl", "shift"], "c")));
                    m.push(mi(Language.I18n.text("ui.t_f3380f7b44bd"), "Ctrl+Shift+V", keys(["ctrl", "shift"], "v")));
                } else if (has) {
                    m.push(mi(Language.I18n.text("ui.t_a8283ade3185"), "Ctrl+Z", keys(["ctrl"], "z")));
                    m.push(mi(Language.I18n.text("ui.t_74273989b096"), "Ctrl+Shift+Z", keys(["ctrl", "shift"], "z")));
                    m.push(msep());
                    m.push(mi(Language.I18n.text("ui.t_1f45f02561f4"), "Ctrl+X", keys(["ctrl"], "x")));
                    m.push(mi(Language.I18n.text("ui.t_e21f935f11d7"), "Ctrl+C", keys(["ctrl"], "c")));
                    m.push(mi(Language.I18n.text("ui.t_f3380f7b44bd"), "Ctrl+V", keys(["ctrl"], "v")));
                    if (browser || editor) m.push(mi(Language.I18n.text("ui.t_7ccc3ec8c488"), "Ctrl+Shift+V", keys(["ctrl", "shift"], "v")));
                    m.push(mi(Language.I18n.text("ui.t_d1ec69e64b96"), "Ctrl+A", keys(["ctrl"], "a")));
                    m.push(msep());
                    m.push(mi(Language.I18n.text("ui.t_a7b1a1eb0573"), "Ctrl+F", keys(["ctrl"], "f")));
                }
                if (has) m.push(msep());
                m.push(mi(Language.I18n.text("ui.t_dbf706cd68d5"), "", function () { root.spotOpen("clip"); }));
                m.push(mi(Language.I18n.text("ui.t_7963f9b689fa"), "", function () { root.spotOpen("emoji"); }));
            } else if (name === "view") {
                if (has) {
                    m.push(mi(fsMode === 2 ? Language.I18n.text("ui.t_5ef4b4a67fa6") : Language.I18n.text("ui.t_534ab6506ea1"), "", disp(["fullscreen-window"])));
                    m.push(msep());
                    m.push(mchk("Floating", "", floating, disp(["toggle-window-floating"])));
                    m.push(dis(mi(Language.I18n.text("ui.t_6d60e99dd1db"), "", disp(["center-window"])), !floating));
                    m.push(dis(mi(Language.I18n.text("ui.t_c6880e1c18bc"), "", disp(["toggle-column-tabbed-display"])), floating));
                    if (!term) {
                        m.push(msep());
                        m.push(mi(Language.I18n.text("ui.t_ef37f4e061bb"), "Ctrl+0", keys(["ctrl"], "0")));
                        m.push(mi(Language.I18n.text("ui.t_5a982cf9dc11"), "Ctrl+=", keys(["ctrl"], "equal")));
                        m.push(mi(Language.I18n.text("ui.t_24649ee0c7a9"), "Ctrl+-", keys(["ctrl"], "minus")));
                    }
                    if (browser || files) {
                        m.push(msep());
                        m.push(mi(Language.I18n.text("language.reload"), "F5", keys([], "F5")));
                        if (browser) {
                            m.push(mi(Language.I18n.text("ui.t_1b5637bb40bc"), "Ctrl+Shift+R", keys(["ctrl", "shift"], "r")));
                            m.push(mi(Language.I18n.text("ui.t_85c1562cd9ce"), "F12", keys([], "F12")));
                        }
                    }
                    m.push(msep());
                }
                m.push(mchk(Language.I18n.text("ui.t_df8c7c89b3e4"), "", root.darkMode, function () { root.darkMode = !root.darkMode; }));
            } else if (name === "window") {
                if (has) {
                    m.push(mi(Language.I18n.text("ui.t_6be4984f1838"), "", function () { Niri.hideActive(); }));
                    m.push(mchk("Zoom", "", fsMode === 1, disp(["maximize-column"])));
                    m.push(mi(floating ? Language.I18n.text("ui.t_f14f70a0a46e") : Language.I18n.text("ui.t_c391949bab97"), "", disp(["toggle-window-floating"])));
                    m.push(msep());
                    m.push(mi(Language.I18n.text("ui.t_d5a7119ca63f"), "", disp(["move-column-left"])));
                    m.push(mi(Language.I18n.text("ui.t_3739c2e41d27"), "", disp(["move-column-right"])));
                    m.push(mi(Language.I18n.text("ui.t_58a0e5102b25"), "", disp(["set-window-width", "+100"])));
                    m.push(mi(Language.I18n.text("ui.t_0a59b62d3fa7"), "", disp(["set-window-width", "-100"])));
                    if (Quickshell.screens.length > 1) m.push(mi(Language.I18n.text("ui.t_592daa0fbdd8"), "", disp(["move-window-to-monitor-next"])));
                    m.push(mi(Language.I18n.text("ui.t_3aa577e6441c"), "", disp(["move-window-to-workspace-down"])));
                    m.push(mi(Language.I18n.text("ui.t_3afb2048a995"), "", disp(["move-window-to-workspace-up"])));
                    m.push(msep());
                }
                m.push(mi(Language.I18n.text("ui.t_db118b1bcd22"), "", function () { Niri.showHidden(); }));
                m.push(mi(Language.I18n.text("ui.t_472dd88a9760"), "", function () { Niri.showHidden(); }));
                var tls = Niri.toplevels.values;
                if (tls.length > 0) m.push(msep());
                for (i = 0; i < tls.length && i < 8; i++) {
                    (function (w) {
                        var t = (w.title && w.title.length > 0) ? w.title : w.appId;
                        m.push(mchk(t, "", w.activated, function () { w.activate(); }));
                    })(tls[i]);
                }
            } else if (name === "help") {
                m.push(mi(Language.I18n.text("ui.t_7336265a0467"), "", function () { root.search(); }));
                if (has) m.push(mi(n + Language.I18n.text("ui.t_cbb79502d895"), "", function () { root.helpFor(id, n); }));
                m.push(msep());
                m.push(mi("niri Keybinds", "", function () { Quickshell.execDetached(["xdg-open", "https://niri-wm.github.io/niri/Configuration:-Key-Bindings.html"]); }));
                m.push(mi("Reload niri Config", "", function () { Quickshell.execDetached(["niri", "msg", "action", "load-config-file"]); }));
                m.push(msep());
                m.push(mi("niri Documentation", "", function () { Quickshell.execDetached(["xdg-open", "https://niri-wm.github.io/niri/"]); }));
                m.push(mi("Quickshell Documentation", "", function () { Quickshell.execDetached(["xdg-open", "https://quickshell.org/docs"]); }));
            }
        }
        return m;
    }

    // ═════════════ SCREENSHOT (Print key) ═════════════
    // Same flow as Noctalia: every output is snapshotted first (grim), the frozen frame is shown dimmed, you drag a region and
    // the final PNG is cropped from that frozen frame, so nothing that moves while you select ends up in the picture.
    property bool shotOpen: false             // the picker overlay is showing
    property bool shotBusy: false             // taking the snapshots
    property int shotId: 0
    readonly property string shotTmp: Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"
    readonly property string shotFinishScript: [
        "d=\"$1\"; sv=\"$2\"; cl=\"$3\"; nt=\"$4\"; tmp=\"$5\"; g=\"$6\"",
        "if [ \"$g\" = '@' ]; then :; elif [ -n \"$g\" ]; then grim -g \"$g\" \"$tmp\"; else grim \"$tmp\"; fi || exit 1",
        "[ -s \"$tmp\" ] || exit 1",
        "f=\"$tmp\"",
        "if [ \"$sv\" = 1 ]; then",
        "  [ -z \"$d\" ] && d=\"$HOME/Pictures/Screenshots\"",
        "  case \"$d\" in '~') d=\"$HOME\";; '~/'*) d=\"$HOME/${d#'~/'}\";; esac",
        "  n=\"$d/Screenshot-$(date +%F_%H-%M-%S).png\"",
        "  mkdir -p \"$d\" && mv -f \"$tmp\" \"$n\" && f=\"$n\"",
        "fi",
        "[ \"$cl\" = 1 ] && wl-copy --type image/png < \"$f\"",
        "if [ \"$nt\" = 1 ]; then if [ \"$f\" = \"$tmp\" ]; then notify-send -a macbar 'Screenshot copied' 'Copied to the clipboard'; else notify-send -a macbar 'Screenshot saved' \"$f\"; fi; fi",
        "[ \"$f\" = \"$tmp\" ] && rm -f \"$tmp\"",
        "true"
    ].join("\n")
    // geom: "" = whole screen, "x,y WxH" = that area, "@" = `tmpPath` already holds the finished PNG (from the picker)
    function shotFinish(geom, tmpPath) {
        playSound("shutter", 0.8);
        var tmp = tmpPath || (shotTmp + "/macshot-out-" + Date.now() + ".png");
        var save = screenshotSave || !screenshotClipboard;          // never end up with nowhere to put it
        Quickshell.execDetached(["sh", "-c", shotFinishScript, "sh", screenshotDir, save ? "1" : "0", screenshotClipboard ? "1" : "0",
                                 screenshotNotify ? "1" : "0", tmp, geom]);
    }
    function shotStart() {
        if (shotOpen) { shotClose(); return; }
        if (shotBusy) return;
        var scr = Quickshell.screens, names = [];
        for (var i = 0; i < scr.length; i++) names.push(scr[i].name);
        if (names.length === 0) return;
        shotBusy = true;
        shotId++;
        shotSnap.command = ["sh", "-c",
            "d=\"$1\"; i=\"$2\"; shift 2; for n in \"$@\"; do grim -t ppm -o \"$n\" \"$d/macshot-$i-$n.ppm\" & done; wait; "
            + "for n in \"$@\"; do [ -s \"$d/macshot-$i-$n.ppm\" ] || exit 1; done", "sh", shotTmp, String(shotId)].concat(names);
        shotSnap.running = true;
    }
    function shotClose() {
        shotOpen = false;
        Quickshell.execDetached(["sh", "-c", "rm -f \"$1\"/macshot-*.ppm", "sh", shotTmp]);
    }
    Process {
        id: shotSnap
        onExited: (code, status) => {
            root.shotBusy = false;
            if (code === 0) root.shotOpen = true;
            else root.shotClose();
        }
    }
    IpcHandler {
        target: "screenshot"
        function region(): void { root.shotStart(); }
        function screen(): void { root.shotFinish("", ""); }
        function window(): void { root.shotWindow(root.activeWin); }
    }
    Variants {
        model: root.shotOpen ? Quickshell.screens : []
        PanelWindow {
            id: shw
            required property var modelData
            screen: modelData
            anchors { left: true; right: true; top: true; bottom: true }
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore

            WlrLayershell.namespace: "macshot"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

            readonly property url snap: "file://" + root.shotTmp + "/macshot-" + root.shotId + "-" + modelData.name + ".ppm"
            readonly property real k: frozen.implicitWidth > 0 ? frozen.implicitWidth / width : 1     // snapshot pixels per logical pixel
            property real ax: 0
            property real ay: 0
            property real px: 0
            property real py: 0
            property real selX: 0
            property real selY: 0
            property real selW: 0
            property real selH: 0
            property bool dragging: false
            property bool grabbing: false
            readonly property bool hasSel: selW > 1 && selH > 1

            function capture(x, y, w, h) {
                if (grabbing) return;
                grabbing = true;
                selX = Math.round(x); selY = Math.round(y); selW = Math.round(w); selH = Math.round(h);
                grabTimer.restart();
            }
            Timer {
                id: grabTimer
                interval: 40                         // let the cut-out settle at its final size before it is grabbed
                onTriggered: {
                    var out = root.shotTmp + "/macshot-out-" + Date.now() + ".png";
                    var kk = shw.k;
                    var ok = cut.grabToImage(function (res) {
                        var saved = res.saveToFile(out);
                        root.shotClose();
                        if (saved) root.shotFinish("@", out);
                    }, Qt.size(Math.max(1, Math.round(shw.selW * kk)), Math.max(1, Math.round(shw.selH * kk))));
                    if (!ok) root.shotClose();
                }
            }

            Item {
                id: sroot
                anchors.fill: parent
                focus: true
                Component.onCompleted: forceActiveFocus()
                NumberAnimation on opacity { from: 0; to: 1; duration: 120 }
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Escape) { root.shotClose(); event.accepted = true; }
                    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                        shw.capture(0, 0, shw.width, shw.height);
                        event.accepted = true;
                    }
                }

                Image { id: frozen; anchors.fill: parent; source: shw.snap; fillMode: Image.Stretch; smooth: true }
                Rectangle { anchors.fill: parent; color: "black"; opacity: 0.42 }

                // the selected area, undimmed. This item is what gets cropped, so nothing else may be drawn inside it
                Item {
                    id: cut
                    visible: shw.hasSel
                    x: shw.selX; y: shw.selY; width: shw.selW; height: shw.selH
                    clip: true
                    Image { x: -cut.x; y: -cut.y; width: shw.width; height: shw.height; source: shw.snap; fillMode: Image.Stretch; smooth: true }
                }
                Rectangle {
                    visible: shw.hasSel && !shw.grabbing
                    x: cut.x - 1; y: cut.y - 1; width: cut.width + 2; height: cut.height + 2
                    color: "transparent"
                    border.width: 1.5
                    border.color: "white"
                }

                // size badge follows the pointer while selecting
                Rectangle {
                    visible: shw.hasSel && !shw.grabbing
                    x: Math.max(8, Math.min(shw.width - width - 8, shw.px + 14))
                    y: Math.max(8, Math.min(shw.height - height - 8, shw.py + 18))
                    width: sizeTxt.implicitWidth + 18; height: 24; radius: 12
                    color: Qt.rgba(0, 0, 0, 0.72)
                    Text {
                        id: sizeTxt
                        anchors.centerIn: parent
                        text: Math.round(shw.selW * shw.k) + " \u00D7 " + Math.round(shw.selH * shw.k)
                        color: "white"
                        font.family: root.fontFamily; font.pixelSize: 12; font.weight: Font.Medium
                    }
                }
                Rectangle {
                    visible: !shw.hasSel && !shw.grabbing
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: 56
                    width: hintTxt.implicitWidth + 28; height: 32; radius: 16
                    color: Qt.rgba(0, 0, 0, 0.72)
                    Text {
                        id: hintTxt
                        anchors.centerIn: parent
                        text: Language.I18n.text("ui.t_ba2252c4f068")
                        color: "white"
                        font.family: root.fontFamily; font.pixelSize: 13
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    cursorShape: Qt.CrossCursor
                    onPressed: m => {
                        if (m.button === Qt.RightButton) { root.shotClose(); return; }
                        if (shw.grabbing) return;
                        shw.dragging = true;
                        shw.ax = m.x; shw.ay = m.y; shw.px = m.x; shw.py = m.y;
                        shw.selX = m.x; shw.selY = m.y; shw.selW = 0; shw.selH = 0;
                    }
                    onPositionChanged: m => {
                        shw.px = m.x; shw.py = m.y;
                        if (!shw.dragging) return;
                        var x2 = Math.max(0, Math.min(shw.width, m.x)), y2 = Math.max(0, Math.min(shw.height, m.y));
                        shw.selX = Math.min(shw.ax, x2); shw.selY = Math.min(shw.ay, y2);
                        shw.selW = Math.abs(x2 - shw.ax); shw.selH = Math.abs(y2 - shw.ay);
                    }
                    onReleased: m => {
                        if (!shw.dragging) return;
                        shw.dragging = false;
                        if (shw.selW >= 4 && shw.selH >= 4) shw.capture(shw.selX, shw.selY, shw.selW, shw.selH);
                        else { shw.selW = 0; shw.selH = 0; }
                    }
                }
            }
        }
    }

    // ═════════════ ANIMATED WALLPAPER: decode only what can be seen ═════════════
    // When windows cover a monitor's desktop (or one is fullscreen) its video pauses; it resumes as soon as the desktop
    // shows again. One check per window event (open / close / move / workspace / fullscreen), nothing in between.
    readonly property bool videoWall: wallpaperVideo !== ""
    property var wallPaused: ({})          // output → paused (video wallpaper)
    // output → its desktop is completely hidden behind windows (or one is fullscreen). Always tracked: the desktop
    // widgets stop drawing on covered screens (culling), and a video wallpaper pauses there.
    property var screenCovered: ({})
    // output → a window is FULLSCREEN there: only then do the desktop widgets stop drawing (a focused or tiled
    // window that merely covers the desktop keeps them alive)
    property var screenFullscreen: ({})
    function updateWindowState() {
        var next = {}, full = {};
        Niri.monitorData.forEach(function(m) {
            var windows = Niri.clients.filter(function(w) { return !w.hidden && w.monitor === m.id; });
            full[m.name] = windows.some(function(w) { return w.fullscreen > 0; });
            next[m.name] = full[m.name];
        });
        root.screenCovered = next; root.screenFullscreen = full;
        var active = root.activeWin || {};
        root.gamingAutoActive = root.gamingAuto && active.fullscreen > 0 && root.gameClassRe.test(active["class"] || "");
    }
    readonly property var gameClassRe: /^(steam_app_\d+|gamescope|minecraft.*|com\.mojang.*|lutris|heroic|.*\.exe)$/i
    Connections { target: Niri; function onUpdated() { root.updateWindowState(); } }
    onGamingAutoChanged: updateWindowState()

    // ═════════════ SETTINGS PERSISTENCE ═════════════
    readonly property string settingsSig: settingKeys.map(function (k) { return JSON.stringify(root[k]); }).join("|")
    property bool settingsReady: false
    onSettingsSigChanged: if (settingsReady) saveTimer.restart()
    Timer { id: saveTimer; interval: 400; onTriggered: root.saveSettings() }

    function saveSettings() {
        var o = {};
        for (var i = 0; i < settingKeys.length; i++) {
            var k = settingKeys[i];
            o[k] = (k === "accent") ? String(root[k]) : root[k];
        }
        store.setText(JSON.stringify(o, null, 2));
    }
    function applySettings(o, keysToApply) {
        if (!o || typeof o !== "object") return;
        for (var i = 0; i < keysToApply.length; i++) {
            var k = keysToApply[i];
            if (o[k] === undefined) continue;
            try { root[k] = o[k]; } catch (err) { }
        }
    }
    function resetSettings() {
        barEnabled = true;
        darkMode = true; accent = "#0a84ff"; fontFamily = "Inter Variable"; glassOpacity = 0.42; glassBlur = 5; barBgOpacity = 0.10; glassRealtime = false;
        barStyle = "liquid"; use24h = true; showDate = true; showSeconds = false; showBatteryPercent = true;
        showTray = true; showSearch = true;
        spotlightEnabled = true; ccEnabled = true; notificationsEnabled = true; clockAppEnabled = true; ccStyle = "tiles";
        barLogoMode = "arch"; barCustomLogoPath = "";
        barWidgets = ["monitoring", "appleMenu", "appMenus", "workspaces", "volume", "keyboard", "notifications", "wifi", "bluetooth", "privacy", "controlCenter", "clock"];
        ccControls = ccDefault.slice();
        statsMigrated = true; modesMigrated = true; statsMetrics = ["cpu", "memory", "network", "disk"]; statsInterval = 1; statsInterface = ""; statsDevice = ""; statsMemoryPercent = false;
        activityPreferences.resetToDefaults();
        barLayoutControl.resetToDefaults();
        if (modes.restored) { modes.set("focus", "off"); modes.set("awake", "off"); }
        nightDesired = false;
    }

    // inherit look from macdock first, then macbar's own file wins
    FileView {
        id: dockStore
        path: root.dockConfigDir + "/settings.json"
        printErrors: false
        onLoaded: {
            try {
                var o = JSON.parse(text());
                root.applySettings(o, ["darkMode", "accent", "fontFamily", "glassOpacity", "glassRim", "glassGrain", "glassLiquid", "glassBlur", "wallpaperPath"]);
                if (o.dockStyle !== undefined) root.barStyle = (o.dockStyle === "liquid") ? "liquid" : "blur";
            } catch (err) { }
            store.path = root.configDir + "/settings.json";
        }
        onLoadFailed: store.path = root.configDir + "/settings.json"
    }
    FileView {
        id: store
        path: ""
        printErrors: false
        onLoaded: {
            try { root.applySettings(SettingsMigrations.migrate(JSON.parse(text())), root.settingKeys); }
            catch (err) { root.modesMigrated = true; root.statsMigrated = true; }
            if (!root.ccMigGame) {
                root.ccMigGame = true;
                var cg = root.ccControls.slice();
                if (cg.indexOf("gaming") < 0) { var ri = cg.indexOf("record"); cg.splice(ri >= 0 ? ri + 1 : cg.length, 0, "gaming"); root.ccControls = cg; }
            }
            if (!root.ccMigRec) {
                root.ccMigRec = true;
                var cl = root.ccControls.slice();
                if (cl.indexOf("record") < 0) { var fi = cl.indexOf("focus"); cl.splice(fi >= 0 ? fi + 1 : cl.length, 0, "record"); root.ccControls = cl; }
            }
            if (!root.statsMigrated) {
                root.statsMigrated = true;
                if (!root.barWidgetEnabled("monitoring")) root.setBarWidget("monitoring", true);
            }
            root.settingsReady = true;
            if (root.barStyle === "liquid") root.startGlass();
        }
        onLoadFailed: { root.modesMigrated = true; root.statsMigrated = true; root.ccMigRec = true; root.settingsReady = true; if (root.barStyle === "liquid") root.startGlass(); }
    }

    // ═════════════ LIQUID GLASS BACKEND (same pipeline as macdock) ═════════════
    property string glassState: "idle"       // idle → building → ready | failed
    readonly property bool liquidActive: barStyle === "liquid" && glassState === "ready" && !gaming
    readonly property string glassShaderSrc: decodeURIComponent(Qt.resolvedUrl("liquidglass.frag").toString().replace("file://", ""))
    readonly property string glassShaderOut: configDir + "/liquidglass.frag.qsb"
    readonly property url glassShaderUrl: "file://" + glassShaderOut

    onBarStyleChanged: if (barStyle === "liquid") startGlass()
    onGlassStateChanged: console.log("[macbar-glass] state:", glassState)
    function startGlass() {
        if (glassState === "ready" || glassState === "building") return;
        glassState = "building";
        qsbProc.running = true;
        hub.refreshWallpaper();
    }
    Process {
        id: qsbProc
        command: ["sh", "-c",
            "mkdir -p \"$(dirname \"$2\")\"; "
            + "for q in qsb qsb6 qsb-qt6 /usr/lib/qt6/bin/qsb /usr/lib64/qt6/bin/qsb /usr/lib/qt/bin/qsb; do "
            + "  if command -v \"$q\" >/dev/null 2>&1; then \"$q\" --qt6 -o \"$2\" \"$1\" && exit 0; fi; "
            + "done; "
            + "[ -f \"$1.qsb\" ] && cp \"$1.qsb\" \"$2\" && exit 0; "
            + "[ -f \"${MACSHELL_SETTINGS_HOME:-$HOME/.config}/macdock/liquidglass.frag.qsb\" ] && cp \"${MACSHELL_SETTINGS_HOME:-$HOME/.config}/macdock/liquidglass.frag.qsb\" \"$2\" && exit 0; "
            + "exit 1",
            "sh", root.glassShaderSrc, root.glassShaderOut]
        stderr: StdioCollector { onStreamFinished: if (text.trim() !== "") console.log("[macbar-glass] qsb:", text.trim()) }
        onExited: (code, status) => root.glassState = (code === 0 ? "ready" : "failed")
    }

    // wallpaper the glass refracts (override → Noctalia settings.toml → awww/swww/swaybg)
    readonly property var wallpaperMap: hub ? hub.wallpaperMap : ({})
    Binding { target: root.hub; property: "barWantsWallpaper"; value: root.liquidActive }
    function wallpaperFor(screenName) {
        var p = wallpaperPath !== "" ? wallpaperPath
              : (wallpaperMap["wallpaper.monitors." + screenName] || wallpaperMap["wallpaper.last"]
                 || wallpaperMap["wallpaper.default"] || "");
        if (p.indexOf("~/") === 0) p = Quickshell.env("HOME") + p.substring(1);
        return p;
    }
    function fileUrl(p) {
        if (p === "") return "";
        if (p.indexOf("file://") === 0) return p;
        return "file://" + encodeURI(p).replace(/#/g, "%23").replace(/\?/g, "%3F");
    }

    // live window geometry for the backdrop (polled only while a glass popover is open)
    readonly property var monData: hub ? hub.monData : []
    readonly property var glassClients: hub ? hub.glassClients : []
    property int popCount: 0
    onBarEnabledChanged: { if (!barEnabled) popCount = 0; clipStart(); }
    Binding { target: root.hub; property: "barWantsGeo"; value: root.liquidActive }
    // window captures are admitted by the shared gate in shell.qml (hub.tlFor): 0.2 s after a window appears, one every 110 ms

    Component.onCompleted: {
        Quickshell.execDetached(["mkdir", "-p", configDir]);
        refreshBrightness();
        refreshWifi();
        refreshKeyboardLayout();
        refreshConnections();
    }

    // ═════════════ SETTINGS ═════════════
    // The settings window now lives in MacDock.qml (one window for the whole shell).
    function openSettings(pane) { if (hub) hub.openSettings(pane || "menubar"); }

    // ═════════════ THE BAR ═════════════
    // ═════════════ NOTIFICATIONS ═════════════
    // Receives org.freedesktop.Notifications on D-Bus (stop dunst / mako / swaync first — only one daemon can own the name).
    // IPC: qs -c MacShell-niri ipc call notifications open | close | clear   (opens on the focused screen)
    signal notifPopRequest(bool open)
    property bool notifDnd: false            // Do Not Disturb: still stored in the centre, but no popups
    property real notifBlur: 14              // blur of the notification glass (smooth two-pass Gaussian, same method as the Blur slider)
    property int notifUnread: 0
    property int notifSeq: 0
    property var notifRefs: ({})
    ListModel { id: notifHist }              // notification centre history, newest first
    ListModel { id: notifToasts }            // popups currently on screen, newest first

    // switched off: no daemon at all, so mako / dunst / swaync can own the D-Bus name instead
    Loader {
        active: root.notificationsEnabled
        sourceComponent: NotificationServer {
            keepOnReload: false
            bodySupported: true
            bodyMarkupSupported: false
            imageSupported: true
            actionsSupported: true
            persistenceSupported: true
            onNotification: n => root.notifReceive(n)
        }
    }
    function notifIndex(model, id) {
        for (var i = 0; i < model.count; i++) if (model.get(i).nid === id) return i;
        return -1;
    }
    // System notifications get the UI sound; apps (Discord, Spotify, browsers…) play their own, so they stay silent here
    readonly property var systemNotifApps: ["", "macbar", "macshell", "settings", "system", "notify-send", "networkmanager", "network",
        "power", "upower", "battery", "udiskie", "udisks", "disks", "polkit", "systemd", "screenshot", "grim", "niri", "bluetooth", "blueman", "updates", "pacman"]
    function isSystemNotif(n) {
        var app = (n.appName || "").toLowerCase();
        try { if (n.hints && (n.hints["sound-file"] || n.hints["sound-name"])) return false; } catch (e) {}
        return systemNotifApps.indexOf(app) >= 0;
    }
    function notifReceive(n) {
        n.tracked = true;
        var id = ++root.notifSeq;
        root.notifRefs[id] = n;
        var ic = "";
        if (n.image && n.image !== "") ic = n.image;
        else if (n.appIcon && n.appIcon !== "") ic = Quickshell.iconPath(n.appIcon, true);
        var urg = 1;
        if (n.urgency === NotificationUrgency.Critical) urg = 2;
        else if (n.urgency === NotificationUrgency.Low) urg = 0;
        var rec = {
            nid: id, app: n.appName || "", summary: n.summary || "", body: n.body || "",
            icon: ic || "", urgency: urg, time: Date.now(),
            timeout: n.expireTimeout > 0 ? Math.round(n.expireTimeout * 1000) : 0
        };
        notifHist.insert(0, rec);
        while (notifHist.count > 60) {
            var old = notifHist.get(notifHist.count - 1).nid;
            notifHist.remove(notifHist.count - 1);
            delete root.notifRefs[old];
        }
        if ((!root.notifDnd || urg === 2) && !root.notifOpen) {
            // the screenshot has its own shutter sound
            if (root.isSystemNotif(n) && !(rec.app === "macbar" && rec.summary.indexOf("Screenshot") === 0)) root.playSound("glass", 0.7);
            notifToasts.insert(0, rec);
            while (notifToasts.count > 4) notifToasts.remove(notifToasts.count - 1);
        }
        if (!root.notifOpen) root.notifUnread++;
        try { n.closed.connect(function () { root.notifToastRemove(id); }); } catch (e) {}
        // apps that update a notification in place (progress, now playing…): push the new text into the popup and
        // the history, the popup then blur-morphs to it
        function upd(role, val) {
            var i = notifIndex(notifToasts, id); if (i >= 0) notifToasts.setProperty(i, role, val || "");
            var j = notifIndex(notifHist, id); if (j >= 0) notifHist.setProperty(j, role, val || "");
        }
        try { n.summaryChanged.connect(function () { upd("summary", n.summary); }); } catch (e) {}
        try { n.bodyChanged.connect(function () { upd("body", n.body); }); } catch (e) {}
    }
    // ── lock screen: the unread notifications, privacy-safe (app name, app icon, time — never the text) ──
    // written to ~/.cache/macshell/lock-notifs.json, which MacLock watches
    onNotifUnreadChanged: lockNotifSave.restart()
    Connections { target: notifHist; function onCountChanged() { lockNotifSave.restart(); } }
    Timer { id: lockNotifSave; interval: 300; onTriggered: root.lockNotifWrite() }
    function appIconFor(app) {
        if (!app) return "";
        var e = null;
        try { e = DesktopEntries.heuristicLookup ? DesktopEntries.heuristicLookup(app) : null; } catch (err) { e = null; }
        var nm = (e && e.icon) ? e.icon : app.toLowerCase();
        return Quickshell.iconPath(nm, true) || "";
    }
    function lockNotifWrite() {
        var out = [], n = Math.min(notifUnread, notifHist.count, 20);
        for (var i = 0; i < n; i++) {
            var r = notifHist.get(i);
            out.push({ id: r.nid, app: r.app || "Notification", icon: appIconFor(r.app), time: r.time });
        }
        Quickshell.execDetached(["sh", "-c", "mkdir -p \"${XDG_CACHE_HOME:-$HOME/.cache}/macshell\" && printf '%s\\n' \"$1\" > \"${XDG_CACHE_HOME:-$HOME/.cache}/macshell/lock-notifs.json.tmp\" && mv -f \"${XDG_CACHE_HOME:-$HOME/.cache}/macshell/lock-notifs.json.tmp\" \"${XDG_CACHE_HOME:-$HOME/.cache}/macshell/lock-notifs.json\"",
            "sh", JSON.stringify(out)]);
    }

    property bool notifOpen: false
    function notifToastRemove(id) {
        var i = notifIndex(notifToasts, id);
        if (i >= 0) notifToasts.remove(i);
    }
    function notifDelete(id) {
        notifToastRemove(id);
        var i = notifIndex(notifHist, id);
        if (i >= 0) notifHist.remove(i);
        var n = root.notifRefs[id];
        if (n) { try { n.dismiss(); } catch (e) {} delete root.notifRefs[id]; }
    }
    // Clear All: every card in Notification Center turns to dust (staggered), then the list is emptied
    signal notifDustAll()
    property bool notifClearing: false
    property var notifMergeFrom: ({})        // nid → {x, y, w} of its popup (ui coordinates) at the moment the panel opened
    property bool notifFlying: false          // cards are flying from the popups into the panel
    onNotifMergeFromChanged: { if (Object.keys(notifMergeFrom).length > 0) { notifFlying = true; flyEnd.restart(); } }
    Timer { id: flyEnd; interval: 900; onTriggered: root.notifFlying = false }
    onNotifOpenChanged: if (!notifOpen) notifMergeFrom = ({})
    function notifClearAnimated() {
        if (notifHist.count === 0) return;
        notifClearing = true;
        notifDustAll();
        notifClearLater.interval = 950 + Math.min(notifHist.count, 12) * 55;
        notifClearLater.restart();
    }
    Timer { id: notifClearLater; onTriggered: { root.notifClear(); root.notifClearing = false; } }
    function notifClear() {
        notifToasts.clear();
        for (var i = 0; i < notifHist.count; i++) {
            var n = root.notifRefs[notifHist.get(i).nid];
            if (n) { try { n.dismiss(); } catch (e) {} }
        }
        notifHist.clear();
        root.notifRefs = ({});
        root.notifUnread = 0;
    }
    function notifActivate(id) {
        var n = root.notifRefs[id];
        if (n) {
            try {
                for (var i = 0; i < n.actions.length; i++)
                    if (n.actions[i].identifier === "default") { n.actions[i].invoke(); break; }
            } catch (e) {}
        }
        notifToastRemove(id);
    }

    // ═════════════ WALLPAPER PICKER (CTRL + ALT + W) ═════════════
    property string wallpaperDir: ""          // "" = ~/Pictures/Wallpapers
    property var wallpaperFavs: []            // favourite image paths, shown first
    property string wallpaperVideo: ""        // animated wallpaper (video) playing right now, "" = a still picture
    property var wpThumbs: ({})               // video path → cached thumbnail
    property var wpPreviews: ({})             // video path → small looping animated WebP (no video player in the shell)
    property string wallpaperCmd: ""          // "" = auto (awww / swww / swaybg); or your own command, {} = the image path
    property real wpBlur: 40                  // blur of the picker glass
    property bool wpOpen: false
    property string wpStatus: ""
    property var wpDirList: []                // images found in the folder
    property var wpFavOk: ({})                // favourites that still exist on disk
    property var wpFiles: []                  // favourites first, then the rest { path, name, fav }
    property string wpQuery: ""               // search filter
    readonly property var wpShown: {          // what the grid shows (wpFiles filtered by the search)
        var q = root.wpQuery.trim().toLowerCase(), f = root.wpFiles;
        if (q === "") return f;
        var out = [];
        for (var i = 0; i < f.length; i++) if (f[i].name.toLowerCase().indexOf(q) >= 0) out.push(f[i]);
        return out;
    }
    function wpResolveDir() {
        var d = (root.wallpaperDir || "").trim();
        if (d === "") d = "~/Pictures/Wallpapers";
        if (d.indexOf("~") === 0) d = Quickshell.env("HOME") + d.substring(1);
        while (d.length > 1 && d.charAt(d.length - 1) === "/") d = d.substring(0, d.length - 1);
        return d;
    }
    readonly property string wpDirEff: { root.wallpaperDir; return root.wpResolveDir(); }
    function wpName(path) {
        var n = path.substring(path.lastIndexOf("/") + 1);
        var k = n.lastIndexOf(".");
        return k > 0 ? n.substring(0, k) : n;
    }
    function wpRebuild() {
        var favs = root.wallpaperFavs || [], inDir = {}, seen = {}, out = [], i;
        for (i = 0; i < root.wpDirList.length; i++) inDir[root.wpDirList[i]] = true;
        for (i = 0; i < favs.length; i++) {
            if (!(inDir[favs[i]] || root.wpFavOk[favs[i]]) || seen[favs[i]]) continue;
            seen[favs[i]] = true;
            out.push({ path: favs[i], name: root.wpName(favs[i]), fav: true, video: root.wpIsVideo(favs[i]), thumb: root.wpThumbs[favs[i]] || "", preview: root.wpPreviews[favs[i]] || "" });
        }
        for (i = 0; i < root.wpDirList.length; i++) {
            var f = root.wpDirList[i];
            if (seen[f]) continue;
            out.push({ path: f, name: root.wpName(f), fav: false, video: root.wpIsVideo(f), thumb: root.wpThumbs[f] || "", preview: root.wpPreviews[f] || "" });
        }
        root.wpFiles = out;
    }
    function wpParse(text) {
        var lines = text.split("\n"), dir = [], ok = {}, th = {}, pv = {};
        for (var i = 0; i < lines.length; i++) {
            var l = lines[i];
            if (l.indexOf("A:") === 0) dir.push(l.substring(2));
            else if (l.indexOf("T:") === 0) { var k = l.indexOf("\t"); if (k > 2) th[l.substring(2, k)] = l.substring(k + 1); }
            else if (l.indexOf("P:") === 0) { var k2 = l.indexOf("\t"); if (k2 > 2) pv[l.substring(2, k2)] = l.substring(k2 + 1); }
            else if (l.indexOf("F:") === 0) ok[l.substring(2)] = true;
        }
        root.wpThumbs = th;
        root.wpPreviews = pv;
        root.wpDirList = dir;
        root.wpFavOk = ok;
        root.wpRebuild();
    }
    function wpRefresh() {
        if (wpScan.running) return;
        var script = [
            'd="$1"; mk="$2"; shift 2',
            '[ "$mk" = "1" ] && [ ! -d "$d" ] && mkdir -p "$d" 2>/dev/null',
            'if [ -d "$d" ]; then find -L "$d" -maxdepth 3 -type f 2>/dev/null | grep -iE "[.](jpe?g|png|webp|bmp|gif|mp4|webm|mkv|mov|m4v)$" | sort -V | sed "s/^/A:/"; fi',
            // animated wallpapers: a cached thumbnail frame per video
            'tc="${XDG_CACHE_HOME:-$HOME/.cache}/macshell/thumbs"; mkdir -p "$tc"',
            'if [ -d "$d" ]; then find -L "$d" -maxdepth 3 -type f 2>/dev/null | grep -iE "[.](mp4|webm|mkv|mov|m4v)$" | while IFS= read -r v; do',
            '  t="$tc/$(printf "%s:%s" "$v" "$(stat -c %Y "$v" 2>/dev/null)" | md5sum | cut -c1-16).jpg"',
            '  [ -s "$t" ] || ffmpeg -loglevel error -y -ss 1 -i "$v" -frames:v 1 -vf "scale=480:-2" "$t" </dev/null >/dev/null 2>&1',
            '  [ -s "$t" ] && printf "T:%s\\t%s\\n" "$v" "$t"',
            // animated preview + optimized playback copy: built once, in the background, at low priority
            '  w="${t%.jpg}.webp"',
            '  if [ -s "$w" ]; then printf "P:%s\\t%s\\n" "$v" "$w"; else :; fi',
            'done; fi',
            'for f in "$@"; do [ -f "$f" ] && echo "F:$f"; done',
            'exit 0'
        ].join("\n");
        wpScan.command = ["sh", "-c", script, "sh", root.wpDirEff, (root.wallpaperDir || "").trim() === "" ? "1" : "0"].concat(root.wallpaperFavs || []);
        wpScan.running = true;
    }
    function wpSetDir(d) {
        root.wallpaperDir = (d || "").trim();
        root.wpStatus = "";
        root.wpRefresh();
    }
    function wpToggleFav(path) {
        var f = (root.wallpaperFavs || []).slice(), i = f.indexOf(path);
        if (i >= 0) f.splice(i, 1); else f.push(path);
        root.wallpaperFavs = f;
        root.wpRebuild();
    }
    function wpIsVideo(p) { return /[.](mp4|webm|mkv|mov|m4v)$/i.test(p || ""); }
    readonly property string setwallScript: Qt.resolvedUrl("macshell-setwall.sh").toString().replace(/^file:\/\//, "")
    // ── light / dark wallpaper pairs (macOS "Automatic / Light / Dark / Dynamic") ──
    property string wallpaperAppearance: "auto"     // auto (follows Dark Mode) | light | dark | dynamic (time of day)
    property string wpPairLight: ""
    property string wpPairDark: ""
    readonly property bool wpHasPair: wpPairLight !== "" && wpPairDark !== ""

    // "<name>-Light.ext" ↔ "<name>-Dark.ext" in the same folder (from the folder scan)
    function wpPairOf(path) {
        var m = /^(.*[-_ ])(light|dark)(\.[a-z0-9]+)$/i.exec(path || "");
        if (!m) return null;
        var other = m[2].toLowerCase() === "light" ? "Dark" : "Light", list = root.wpDirList, cand = null;
        for (var i = 0; i < list.length; i++) {
            var mm = /^(.*[-_ ])(light|dark)(\.[a-z0-9]+)$/i.exec(list[i]);
            if (mm && mm[1] === m[1] && mm[2].toLowerCase() === other.toLowerCase()) { cand = list[i]; break; }
        }
        if (!cand) return null;
        return m[2].toLowerCase() === "light" ? { light: path, dark: cand } : { light: cand, dark: path };
    }
    function hhmmToMin(t) { var m = /T(\d+):(\d+)/.exec(t || ""); return m ? parseInt(m[1]) * 60 + parseInt(m[2]) : -1; }
    // Sets a picture as the real desktop wallpaper: awww first (its daemon is started if needed), then the other daemons.
    // $1 = image path. Also stops a running animated wallpaper (mpvpaper) so it does not stay on top of the picture.
    readonly property string awwwScript: 'exec "$2" "$1"'
    property string wpAppliedPair: ""
    function wpApplyAppearance() {
        if (!wpHasPair) return;
        var mode = wallpaperAppearance === "auto" ? (darkMode ? "dark" : "light") : wallpaperAppearance;
        var rise = 390, set_ = 1110;
        try {
            var wx = root.hub && root.hub.widgets ? root.hub.widgets.weather : null;
            if (wx && wx.daily && wx.daily.sunrise) { var a = hhmmToMin(wx.daily.sunrise[0]), b2 = hhmmToMin(wx.daily.sunset[0]); if (a > 0) rise = a; if (b2 > 0) set_ = b2; }
        } catch (e) {}
        if (mode === "dynamic") { var d = new Date(), n = d.getHours() * 60 + d.getMinutes(); mode = (n >= rise && n < set_) ? "light" : "dark"; }
        var p = mode === "dark" ? wpPairDark : wpPairLight;
        if (p === "") return;
        root.wallpaperVideo = "";
        root.wallpaperPath = p;
        try { if (root.hub && root.hub.dock) root.hub.dock.wallpaperPath = p; } catch (e) {}
        if (p === root.wpAppliedPair) return;                         // already on screen
        root.wpAppliedPair = p;
        wpApplyProc.command = ["sh", "-c", root.awwwScript, "sh", p, root.setwallScript];  // the real desktop wallpaper, through awww
        wpApplyProc.running = true;
    }
    onWallpaperAppearanceChanged: wpApplyAppearance()
    onDarkModeChanged: {
        invalidateTone();
        if (wallpaperAppearance === "auto") wpApplyAppearance();
    }
    Timer { interval: 60000; repeat: true; running: root.wpHasPair && root.wallpaperAppearance === "dynamic" && !root.gaming; onTriggered: root.wpApplyAppearance() }
    // at start: scan the folder, then pick up a pair for the wallpaper already in use
    Timer { interval: 1500; running: true; onTriggered: root.wpRefresh() }
    onWpDirListChanged: {
        if (wpHasPair) return;
        var p = wpPairOf(wallpaperPath);
        if (p) { wpPairLight = p.light; wpPairDark = p.dark; wpApplyAppearance(); }
    }
    Timer { interval: 2500; running: true; onTriggered: root.wpApplyAppearance() }

    function wpApply(path) {
        var pair = wpPairOf(path);
        if (pair) { wpPairLight = pair.light; wpPairDark = pair.dark; root.wpAppliedPair = ""; wpApplyAppearance(); return; }
        wpPairLight = ""; wpPairDark = ""; root.wpAppliedPair = "";
        // animated wallpapers go through macshell-setwall.sh (mpvpaper for videos); pictures are always set with awww below
        if (root.wpIsVideo(path)) {
            root.wallpaperVideo = path;
            setwallProc.command = [root.setwallScript, path];
            setwallProc.running = true;
            return;
        }
        root.wallpaperVideo = "";
        root.wallpaperPath = path;                                            // the glass refracts the new image straight away
        try { if (root.hub && root.hub.dock) root.hub.dock.wallpaperPath = path; } catch (e) {}
        var cmd = (root.wallpaperCmd || "").trim();
        var script = cmd !== "" ? cmd.split("{}").join('"$1"') : root.awwwScript;
        wpApplyProc.command = ["sh", "-c", script, "sh", path, root.setwallScript];
        wpApplyProc.running = true;
    }
    Process {
        id: setwallProc
        stdout: StdioCollector {
            onStreamFinished: {
                var l = text.trim().split("\n"), still = (l[l.length - 1] || "").trim();
                if (still === "") return;
                root.wallpaperPath = still;
                try { if (root.hub && root.hub.dock) root.hub.dock.wallpaperPath = still; } catch (e) {}
            }
        }
        stderr: StdioCollector { onStreamFinished: if (text.trim() !== "") console.log("[wallpaper] error:", text.trim()) }
    }
    Process {
        id: wpApplyProc
        stdout: StdioCollector { onStreamFinished: if (text.trim() !== "") console.log("[wallpaper]", text.trim()) }
        stderr: StdioCollector { onStreamFinished: if (text.trim() !== "") console.log("[wallpaper] error:", text.trim()) }
    }
    function wpToggle() {
        root.wpOpen = !root.wpOpen;
        if (root.wpOpen) root.wpRefresh();
    }
    function wpPickFolder() {
        var script = [
            'd="$1"; [ -d "$d" ] || d="$HOME"',
            'if command -v zenity >/dev/null 2>&1; then zenity --file-selection --directory --filename="$d/" --title="Wallpaper folder" 2>/dev/null',
            'elif command -v kdialog >/dev/null 2>&1; then kdialog --getexistingdirectory "$d" 2>/dev/null',
            'elif command -v yad >/dev/null 2>&1; then yad --file --directory --filename="$d/" 2>/dev/null',
            'else echo "!nopicker"; fi',
            'exit 0'
        ].join("\n");
        wpPick.command = ["sh", "-c", script, "sh", root.wpDirEff];
        root.wpOpen = false;                       // the overlay would sit on top of the dialog, so hide it meanwhile
        wpPick.running = true;
    }
    Process { id: wpScan; stdout: StdioCollector { onStreamFinished: root.wpParse(text) } }
    Process {
        id: wpPick
        stdout: StdioCollector {
            onStreamFinished: {
                var r = text.trim();
                if (r === "!nopicker") root.wpStatus = "No folder dialog found (install zenity or kdialog) - type the path instead.";
                else if (r !== "") root.wpSetDir(r);
                root.wpOpen = true;
                root.wpRefresh();
            }
        }
    }
    onWallpaperFavsChanged: if (wpOpen) wpRebuild()
    IpcHandler {
        target: "wallpapers"
        function toggle(): void { root.wpToggle(); }
        // qs -c MacShell-niri ipc call wallpapers appearance auto|light|dark|dynamic
        function set(path: string): void { root.wpApply(path); }
        function appearance(mode: string): void { if (["auto", "light", "dark", "dynamic"].indexOf(mode) >= 0) root.wallpaperAppearance = mode; }
        function open(): void { if (!root.wpOpen) root.wpToggle(); }
        function close(): void { root.wpOpen = false; }
    }

    // ═════════════ WORKSPACES (centre of the bar) ═════════════
    function focusWorkspace(id) { Niri.focusWorkspace(Number(id)); }
    property int wsMin: 0
    readonly property var wsIds: Niri.workspaces.values.map(function(w) { return w.id; })
    function workspaceIdsFor(output) {
        return Niri.workspaces.values.filter(function(w) { return w.output === output; })
            .sort(function(a, b) { return a.idx - b.idx; }).map(function(w) { return w.id; });
    }
    function wsOccupied(id) {
        return Niri.clients.some(function(w) { return w.workspace_id === id; });
    }

    // ═════════════ WINDOW SWITCHER (ALT + TAB) ═════════════
    // Alt+Tab bindings are generated from config/macshell.kdl.
    property real switcherBlur: 15           // blur of the switcher glass (smooth Gaussian; less than Spotlight / notifications)
    property string switcherStyle: "glass"   // glass (Liquid Glass) | frosted | opaque — Settings → Desktop & Dock
    property bool swOpen: false
    property var swApps: []                  // open apps, most recently used first: { appId, name, icon, win, count }
    property int swIndex: 0
    property var swMru: []                   // recently focused toplevels, newest first
    function swTrack() {
        var t = root.activeTl;
        if (!t) return;
        var a = [t];
        for (var i = 0; i < root.swMru.length && a.length < 60; i++) if (root.swMru[i] !== t) a.push(root.swMru[i]);
        root.swMru = a;
    }
    function swIcon(a) {
        if (a.icon) return root.iconSrc(a.icon);
        var p = Quickshell.iconPath(a.appId, true);
        if (p === "") p = Quickshell.iconPath(a.appId.toLowerCase(), true);
        return p !== "" ? p : root.iconSrc("");
    }
    function swBuild() {
        var vals = Niri.toplevels.values, all = [];
        for (var i = 0; i < vals.length; i++) all.push(vals[i]);
        var order = [];
        if (root.activeTl && all.indexOf(root.activeTl) >= 0) order.push(root.activeTl);       // the app you are in comes first
        for (var m = 0; m < root.swMru.length; m++) if (all.indexOf(root.swMru[m]) >= 0 && order.indexOf(root.swMru[m]) < 0) order.push(root.swMru[m]);
        for (var j = 0; j < all.length; j++) if (order.indexOf(all[j]) < 0) order.push(all[j]);
        var seen = {}, apps = [];
        for (var k = 0; k < order.length; k++) {
            var t = order[k], id = t.appId || "";
            if (id === "") continue;
            // MacShell's own windows (all "org.quickshell") are separate apps: Clock, System Settings
            if (id === "org.quickshell" || id === "dev.noctalia.noctalia-qs") id = Utilities.windowId(t.title) || (t.title === "Clock" ? "macshell-clock"
                                             : (t.title === "App Store" ? "macshell-appstore"
                                             : (t.title === "macshell Settings" ? "systemsettings" : id)));
            if (seen[id] !== undefined) { apps[seen[id]].count++; continue; }
            var e = root.lookup(id);
            seen[id] = apps.length;
            apps.push({ appId: id, cls: t.appId, name: id === "systemsettings" ? Language.I18n.text("ui.t_1f87f883cc7e") : (e ? e.name : id),
                        icon: id === "systemsettings" ? "preferences-system" : (e ? e.icon : ""), win: t, count: 1 });
        }
        return apps;
    }
    function swNext(dir) {
        if (!root.swOpen) {
            var apps = root.swBuild();
            if (apps.length === 0) return;
            root.swApps = apps;
            root.swIndex = 0;                // 0 = the app you are in, so the first TAB lands on the previous one
            root.swOpen = true;
        }
        var n = root.swApps.length;
        root.swIndex = (root.swIndex + (dir >= 0 ? 1 : n - 1)) % n;
    }
    // Release the exclusive layer before requesting focus, using the stable niri ID.
    property var swPending: null
    Timer {
        id: swFocusTimer; interval: 60
        onTriggered: { var window = root.swPending; root.swPending = null; if (window && Niri.windowMap[String(window.id)]) Niri.action(["focus-window", "--id", String(window.id)]); }
    }
    function swCommit() {
        if (!swOpen) return;
        var item = swApps[swIndex]; swOpen = false;
        if (item && item.win) { swPending = { id: item.win.id }; swFocusTimer.restart(); }
    }
    function swCancel() { root.swOpen = false; }
    IpcHandler {
        target: "switcher"
        function next(): void { root.swNext(1); }
        function prev(): void { root.swNext(-1); }
        function commit(): void { root.swCommit(); }
        function cancel(): void { root.swCancel(); }
    }

    // An independent, input-transparent overlay remains above fullscreen windows
    // and works even when the Menu Bar and Control Center are disabled.
    Variants {
        model: root.settingsReady ? Quickshell.screens : []
        PanelWindow {
            id: osdWindow
            required property var modelData
            property var glassSurfaces: []
            readonly property bool targetScreen: modelData.name === (Niri.focusedMonitor ? Niri.focusedMonitor.name : Quickshell.screens[0].name)
            screen: modelData
            anchors { top: true; right: true }
            margins { top: root.barHeight + 14; right: 22 }
            implicitWidth: 308; implicitHeight: 92
            color: "transparent"
            visible: targetScreen && (levelFeedback.visible || osdSurface.opacity > 0)
            exclusionMode: ExclusionMode.Ignore
            mask: Region {}
            WlrLayershell.namespace: "macosd"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            BackgroundEffect.blurRegion: GlassRegion { host: osdWindow }
            Item {
                id: osdSurface
                anchors.fill: parent; anchors.margins: 8
                opacity: levelFeedback.visible ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 160 } }
                GlassFallback {
                    anchors.fill: parent; radius: 24
                    dark: root.darkMode
                    frosting: Math.max(.6, root.glassOpacity)
                    intensity: root.glassLiquid
                    blurAmount: root.glassBlur
                    blurEnabled: !root.gaming
                }
                LevelOsd {
                    anchors.fill: parent
                    kind: levelFeedback.kind; value: levelFeedback.value; muted: levelFeedback.muted
                    foreground: root.darkMode ? "#f7f7fa" : "#1d1d1f"
                    fontFamily: root.fontFamily
                }
            }
        }
    }
    IpcHandler {
        target: "osd"
        function state(): string {
            return JSON.stringify({visible: levelFeedback.visible, kind: levelFeedback.kind,
                value: levelFeedback.value, muted: levelFeedback.muted, volume: root.volume,
                outputMuted: root.muted, brightness: root.brightness, microphoneMuted: root.micMuted});
        }
    }

    Variants {
        model: (root.settingsReady && root.barLayerNeeded) ? Quickshell.screens : []

        Scope {
            id: perScreen
            required property var modelData

            BarInk {
                id: barInk
                property string registeredName: ""
                screen: perScreen.modelData; barHeight: root.barHeight; darkMode: root.darkMode
                active: root.barEnabled && root.autoContrast && !(root.barGlass && root.liquidActive) && root.barBgOpacity < .5
                contextKey: JSON.stringify([root.darkMode, root.barBgOpacity, root.barGlass, root.liquidActive,
                    screen ? [screen.x, screen.y, screen.width, screen.height] : [],
                    Niri.activeToplevel ? [Niri.activeToplevel.id, Niri.activeToplevel.fullscreen] : [],
                    Niri.focusedWorkspace ? Niri.focusedWorkspace.id : -1, Niri.overview, root.hub ? root.hub.wallpaperMap : {}])
                function publish() {
                    var next = Object.assign({}, root.barInks);
                    next[perScreen.modelData.name] = {adaptive: active, light: lightInk, status: status};
                    root.barInks = next;
                }
                onLightInkChanged: publish()
                onStatusChanged: publish()
                Component.onCompleted: { registeredName = perScreen.modelData.name; publish(); }
                Component.onDestruction: {
                    var next = Object.assign({}, root.barInks); delete next[registeredName]; root.barInks = next;
                }
            }
            QtObject {
                id: screenPal
                readonly property bool dark: barInk.lightInk
                readonly property string fam: root.fontFamily
                readonly property color accent: root.accent
                readonly property color fg: dark ? "#FFFFFF" : barInk.active ? "#000000" : "#1D1D1F"
                readonly property color fg2: dark ? Qt.rgba(1, 1, 1, 0.62) : Qt.rgba(0, 0, 0, 0.68)
                readonly property color fg3: dark ? Qt.rgba(1, 1, 1, 0.34) : Qt.rgba(0, 0, 0, 0.48)
                readonly property color tile: dark ? Qt.rgba(1, 1, 1, 0.10) : Qt.rgba(1, 1, 1, 0.42)
                readonly property color tileBorder: dark ? Qt.rgba(1, 1, 1, 0.16) : Qt.rgba(1, 1, 1, 0.70)
                readonly property color btnOff: dark ? Qt.rgba(1, 1, 1, 0.20) : Qt.rgba(0, 0, 0, 0.10)
                readonly property color btnHover: dark ? Qt.rgba(1, 1, 1, 0.30) : Qt.rgba(0, 0, 0, 0.16)
                readonly property color hover: dark ? Qt.rgba(1, 1, 1, 0.14) : Qt.rgba(0, 0, 0, 0.09)
                readonly property color sep: dark ? Qt.rgba(1, 1, 1, 0.14) : Qt.rgba(0, 0, 0, 0.12)
                readonly property color track: dark ? Qt.rgba(1, 1, 1, 0.20) : Qt.rgba(0, 0, 0, 0.12)
                readonly property color content: dark ? "#1E1E1E" : "#F5F5F7"
                readonly property color card: dark ? "#2B2B2D" : "#FFFFFF"
                readonly property color cardBorder: dark ? Qt.rgba(1, 1, 1, 0.07) : Qt.rgba(0, 0, 0, 0.08)
                readonly property color switchOff: dark ? Qt.rgba(1, 1, 1, 0.22) : Qt.rgba(0, 0, 0, 0.16)
            }

        // ═════════ the bar's background lives in its OWN layer (namespace "macbarbg") ═════════
        // niri blurs a whole layer or none of it, and the bar window also carries the popovers, so the bar strip is a separate
        // layer just under the bar: it paints a translucent fill (Settings → Menu Bar → Bar background) and takes no input.
        // Blur it with:  layerrule = blur, macbarbg   +   layerrule = ignorealpha 0.05, macbarbg
        PanelWindow {
            id: barBgWin
            screen: perScreen.modelData
            visible: root.barBgOpacity > 0.001
            anchors { left: true; right: true; top: true }
            implicitHeight: root.barHeight
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            mask: Region { }

            WlrLayershell.namespace: "macbarbg"
            // Top, not Bottom: on Bottom it sat under the windows, so it only ever blurred the wallpaper — over a
            // window there was nothing behind it to blur. It is declared before the bar itself, so it stacks under it.
            WlrLayershell.layer: WlrLayer.Top
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

            Rectangle {
                anchors.fill: parent
                color: root.darkMode ? Qt.rgba(0.10, 0.10, 0.11, root.barBgOpacity) : Qt.rgba(1, 1, 1, root.barBgOpacity)
            }
        }

        PanelWindow {
            id: win
            property var glassSurfaces: []
            BackgroundEffect.blurRegion: GlassRegion { host: win }
            property var modelData: perScreen.modelData
            screen: perScreen.modelData

            anchors { left: true; right: true; top: true }
            implicitHeight: root.barHeight + root.popRoom
            color: "transparent"

            exclusionMode: ExclusionMode.Normal
            exclusiveZone: root.barEnabled ? root.barHeight : 0

            WlrLayershell.namespace: "macbar"
            WlrLayershell.layer: WlrLayer.Top
            WlrLayershell.keyboardFocus: ui.pop !== "" && ui.pop !== "spot" && root.popupOwner === win.modelData.name ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

            IdleInhibitor { window: win; enabled: root.keepAwake && win.modelData === Quickshell.screens[0] }
            mask: Region { item: maskItem; Region { item: toastMask } }

            Item {
                id: ui
                anchors.fill: parent

                Keys.onEscapePressed: event => { if (pop !== "") { if (anchorType === "controlCenter" && (pop === "wifi" || pop === "bt")) pop = "cc"; else { if (pop === "btpair") root.bluetooth.cancel(); if (pop === "wifijoin") root.wifi.cancel(); if (pop === "record" && root.recorder.state === "countdown") root.recorder.cancel(); pop = ""; } event.accepted = true; } }
                Connections {
                    target: root
                    function onControlRequested(name) {
                        if (name === "airdrop") { ui.pop = ""; return; }
                        if (name.indexOf("close-") === 0) { if (ui.pop === name.substring(6)) ui.pop = ""; return; }
                        var prompt = name === "wifijoin" || name === "btpair" || name === "record" || name === "airplay";
                        var ownerExists = Quickshell.screens.some(s => s.name === root.interactionScreen);
                        if ((prompt && ownerExists ? root.interactionScreen === win.modelData.name : ui.toastScreen) && ui.pop !== name) ui.openPop(name, ui.width - 150);
                    }
                    function onMonitoringRequested(outputName) {
                        if (win.modelData.name === outputName && ui.pop !== "stats") ui.openPop("stats", ui.width - 150);
                    }
                    function onPopupOwnerChanged() { if (root.popupOwner !== "" && root.popupOwner !== win.modelData.name) ui.pop = ""; }
                }
                Component.onDestruction: {
                    if (root.popupOwner === win.modelData.name) {
                        root.popupOwner = ""; root.activeControl = "";
                        if (root.bluetooth.prompt || root.wifi.prompt) Qt.callLater(() => root.controlRequested(root.bluetooth.prompt ? "btpair" : "wifijoin"));
                    }
                }
                property string pop: ""          // "", apple, app, file, edit, view, window, help, cc, cal
                property real menuX: 0
                property string anchorType: ""
                property bool anchorOverflow: false
                function typeForPopup(name) {
                    return ({apple: "appleMenu", app: "appMenus", file: "appMenus", edit: "appMenus", view: "appMenus", window: "appMenus", help: "appMenus", stats: "monitoring", bt: "bluetooth", vol: "volume", kb: "keyboard", battery: "battery", notif: "notifications", wifi: "wifi", cc: "controlCenter", cal: "clock"})[name] || "";
                }
                function updateAnchor() {
                    if (!anchorType || pop === "") return;
                    var slot = barBg.plan.byType[anchorType];
                    if (anchorOverflow) {
                        if (!barBg.plan.overflow.some(item => item.type === anchorType)) { pop = ""; return; }
                        menuX = overflowButton.mapToItem(ui, overflowButton.width / 2, 0).x;
                    } else if (!slot || slot.width <= 0) pop = "";
                    else if (isMenu || anchorType === "tray" && pop === "tray") {
                        var item = childAnchor(anchorType === "appleMenu" ? appleSlot : anchorType === "appMenus" ? appSlot : traySlot, isMenu ? pop : trayItem);
                        if (!item) {
                            if (anchorType === "appMenus" && slot.mode > 0) menuX = barContent.mapToItem(ui, slot.x + slot.width / 2, 0).x;
                            else pop = "";
                            return;
                        }
                        menuX = item.mapToItem(ui, 0, 0).x;
                    } else menuX = barContent.mapToItem(ui, slot.x + slot.width / 2, 0).x;
                }
                function childAnchor(slot, key) {
                    for (var i = 0; i < slot.children.length; i++) {
                        var children = slot.children[i].children;
                        if (!children) continue;
                        for (var j = 0; j < children.length; j++) {
                            var data = children[j].modelData;
                            if (data && (typeof key === "string" ? data.id === key : data === key)) return children[j];
                        }
                    }
                    return null;
                }
                function popupX(width, zoom, origin, leading) {
                    var factor = origin === Item.TopRight ? 1 : origin === Item.Top ? .5 : 0;
                    return BarLayout.popupX(menuX, width, zoom, factor, ui.width, !!leading);
                }
                readonly property var overflowEntries: {
                    if (pop === "appmenus") return root.menuTitles.filter(item => item.id !== "apple").map(item => ({type: "appMenus", label: item.label, target: item.id}));
                    var entries = [];
                    barBg.plan.overflow.forEach(block => {
                        if (block.type === "tray") SystemTray.items.values.forEach(item => entries.push({type: "tray", label: item.title || Language.I18n.text("ui.t_c3418e8ce8e0"), item: item}));
                        else if (block.type === "appMenus") root.menuTitles.filter(item => item.id !== "apple").forEach(item => entries.push({type: block.type, label: item.label, target: item.id}));
                        else if (block.type === "workspaces") root.workspaceIdsFor(perScreen.modelData.name).forEach(id => entries.push({type: block.type, label: Language.I18n.text("ui.t_32bb3156b167") + Niri.workspaceLabel(id), target: id}));
                        else entries.push({type: block.type, label: BarLayout.label(root.barLayout.catalog, block.type)});
                    });
                    return entries;
                }
                function activateOverflow(entry, button) {
                    if (entry.type === "tray") {
                        if (button === Qt.RightButton || button === Qt.LeftButton && entry.item.onlyMenu) {
                            anchorType = "tray"; anchorOverflow = true;
                            openTray(entry.item, overflowButton.mapToItem(ui, 0, 0).x, true);
                        } else { pop = ""; if (button === Qt.MiddleButton) entry.item.secondaryActivate(); else entry.item.activate(); }
                        return;
                    }
                    if (entry.type === "keyboard" && button !== Qt.RightButton) { root.cycleKeyboardLayout(1); return; }
                    if (entry.type === "workspaces") { pop = ""; root.focusWorkspace(String(entry.target)); return; }
                    if (entry.type === "search") { pop = ""; if (root.launcher !== "") root.search(); else openPop("spot", 0); return; }
                    var names = {appleMenu: "apple", appMenus: entry.target, monitoring: "stats", bluetooth: "bt", volume: "vol", keyboard: "kb", battery: "battery", notifications: "notif", wifi: "wifi", controlCenter: "cc", privacy: "cc", clock: "cal"};
                    if (names[entry.type]) openPop(names[entry.type], menuX, pop === "overflow", entry.type);
                }
                property var menuModel: []
                property string armed: ""
                property int calYear: 2026
                property int calMonth: 0
                property string wifiPrompt: ""      // ssid whose password field is open in the Wi-Fi popover
                property bool ccEdit: false         // Control Center is in "Edit Controls" mode
                property var trayItem: null         // SystemTrayItem whose menu is open in the tray popover
                property var trayStack: []          // submenu path (QsMenuEntry objects) inside that menu
                Timer { interval: 400; repeat: true; running: ui.pop === "vol"; onTriggered: root.audioTick++ }
                readonly property bool toastScreen: Quickshell.screens.length === 1 || (Niri.focusedMonitor !== null && Niri.focusedMonitor.name === win.modelData.name)
                // the Control Center IPC: the focused screen opens it
                Connections {
                    target: root
                    function onCcRequest(open) {
                        if (!ui.toastScreen || !root.ccEnabled) return;
                        if (open && ui.pop !== "cc") ui.openPop("cc", ui.width - 150); else ui.pop = "";
                    }
                }
                readonly property bool toastsShown: toastScreen && notifToasts.count > 0
                // notifications arriving with no panel open: measure what's behind the banners
                onToastsShownChanged: if (toastsShown && pop === "") root.measureTone(win.modelData.x + ui.width - 374, win.modelData.y + root.barHeight + 8, 364, 90)

                function openTray(item, x, fromOverflow) {
                    if (!item || !item.hasMenu) return;
                    if (pop === "tray" && trayItem === item) { pop = ""; return; }
                    anchorType = "tray"; anchorOverflow = !!fromOverflow;
                    trayStack = [];
                    trayItem = item;
                    menuX = x;
                    pop = "tray"; updateAnchor();
                }

                function wifiPick(n) { root.wifi.pick(n); }
                function wifiSubmit(ssid, pw) { if (root.wifi.prompt) root.wifi.join(root.wifi.prompt, pw); }
                Timer {
                    interval: 4000; repeat: true
                    running: ui.pop === "wifi" && ui.wifiPrompt === ""     // paused while typing so the list doesn't rebuild under the cursor
                    onTriggered: root.scanWifi()
                }
                Timer {
                    interval: 2000; repeat: true
                    running: ui.pop === "bt" && !root.bluetooth.busy
                    onTriggered: root.refreshBt()
                }

                // Spotlight state
                property string spMode: "home"          // home | actions | apps
                property string spQuery: ""
                property string spHoverLabel: ""
                property int spSel: 0
                property int spSavedSel: 0
                property var spActionItem: null
                readonly property var spActionList: {
                    var tick = root.desktopSourceTick;
                    return spActionItem ? root.spotlightActions(spActionItem) : [];
                }
                property var spExpanded: ({})
                property bool clipMenu: false           // the round "..." menu of the Clipboard panel
                property bool spCalm: false             // Spotlight was opened by the clipboard / emoji shortcut: plain fade, no springy pop
                property bool spReqCalm: false
                property int emCat: 0                   // emoji category tab (0 = recents)
                property bool spHover: false            // spSel was just changed by the pointer, so lists must not scroll to it
                readonly property int emCols: 12
                readonly property bool spFull: spMode === "apps" || spMode === "clip" || spMode === "emoji"
                property var spResults: spMode === "actions" ? root.actionItems(spQuery)
                                        : (spMode === "clip" ? root.clipFiltered(spQuery)
                                        : (spMode === "emoji" ? root.emojiItems(spQuery, emCat)
                                        : (spQuery.trim() === "" ? [] : root.homeItems(spQuery))))

                function spSetMode(m) {
                    spCloseActions();
                    spMode = m; spQuery = ""; spHoverLabel = ""; spSel = 0; armed = ""; clipMenu = false;
                    spInput.text = ""; appsInput.text = ""; clipInput.text = ""; emojiInput.text = "";
                    if (m === "clip") root.clipRefresh();
                    if (m === "emoji") emCat = root.emojiRecent.length > 0 ? 0 : 1;
                    spFocusTimer.restart();
                }
                function spEscape() {
                    if (spActionItem) spCloseActions();
                    else if (clipMenu) clipMenu = false;
                    else if (spQuery !== "") { spInput.text = ""; appsInput.text = ""; clipInput.text = ""; emojiInput.text = ""; spQuery = ""; }
                    else if (spMode !== "home") spSetMode("home");
                    else pop = "";
                }
                function spList() { return spActionItem ? spActionList : spResults; }
                function spMove(d) {
                    resPanel.pointerSelection = false;
                    var n = spList().length;
                    if (n > 0) spSel = (Math.min(spSel, n - 1) + d + n) % n;
                }
                function spOpenActions(item) {
                    if (!item || !SettingsSearch.hasExtras(item.kind)) return;
                    spSavedSel = spSel;
                    spActionItem = item;
                    spSel = 0;
                    armed = "";
                    resPanel.pointerSelection = false;
                    if (item.kind === "app" && item.appId && root.hub && root.hub.desktopSource)
                        root.hub.desktopSource.request(item.appId);
                }
                function spCloseActions() {
                    if (!spActionItem) return;
                    spActionItem = null;
                    spSel = spSavedSel;
                    armed = "";
                }
                function spActivate(i) {
                    var list = spList();
                    var it = list[i];
                    if (!it) return;
                    if (spActionItem) {
                        if (it.enabled === false) return;
                        if (it.confirm === true && armed !== it.title) { armed = it.title; return; }
                        if (it.close !== false) pop = "";
                        if (it.run) it.run();
                        if (it.close === false) spCloseActions();
                        return;
                    }
                    if (it.confirm === true && armed !== it.title) { armed = it.title; return; }
                    pop = "";
                    if (it.run) it.run();
                }
                function spEnter() {
                    if (spMode === "apps") {
                        var r = root.searchApps(spQuery);
                        if (r.length > 0) { pop = ""; root.launchApp(r[0]); }
                    } else if (spMode === "emoji") {
                        var em = spResults[Math.min(spSel, spResults.length - 1)];
                        if (em) { pop = ""; root.emojiPick(em); }
                    } else spActivate(Math.min(spSel, spList().length - 1));
                }
                function spKey(ev) {
                    var k = ev.key, n = spResults.length;
                    if (k === Qt.Key_Escape) { spEscape(); ev.accepted = true; }
                    else if (spMode === "emoji" && (k === Qt.Key_Left || k === Qt.Key_Right || k === Qt.Key_Up || k === Qt.Key_Down)) {
                        var d = k === Qt.Key_Left ? -1 : (k === Qt.Key_Right ? 1 : (k === Qt.Key_Up ? -emCols : emCols));
                        if (n > 0) spSel = Math.max(0, Math.min(n - 1, Math.min(spSel, n - 1) + d));
                        ev.accepted = true;
                    }
                    else if (spMode === "emoji" && (k === Qt.Key_Tab || k === Qt.Key_Backtab)) {
                        if (spQuery.trim() === "") { emCat = (emCat + (k === Qt.Key_Tab ? 1 : 9)) % 10; spSel = 0; }
                        ev.accepted = true;
                    }
                    else if (k === Qt.Key_Down) { spMove(1); ev.accepted = true; }
                    else if (k === Qt.Key_Up) { spMove(-1); ev.accepted = true; }
                    else if (k === Qt.Key_Right && !spActionItem && n > 0) {
                        spOpenActions(spResults[Math.min(spSel, n - 1)]);
                        ev.accepted = true;
                    }
                    else if (k === Qt.Key_Left && spActionItem) {
                        spCloseActions();
                        ev.accepted = true;
                    }
                    else if (spMode === "clip" && k === Qt.Key_Delete) {
                        if (n > 0) root.clipDelete(spResults[Math.min(spSel, n - 1)]);
                        ev.accepted = true;
                    }
                    else if (k === Qt.Key_Y && (ev.modifiers & Qt.ControlModifier)) {
                        var ql = ui.spActionItem || (n > 0 ? spResults[Math.min(spSel, n - 1)] : null);
                        if (ql && ql.kind === "file") { root.openQuickLook(ql.path); ev.accepted = true; }
                    }
                    else if (k === Qt.Key_Return || k === Qt.Key_Enter) {
                        if (spMode === "clip" && (ev.modifiers & Qt.ShiftModifier) && n > 0) {
                            var it = spResults[Math.min(spSel, n - 1)];
                            pop = "";
                            root.clipPick(it, false);       // Shift+Return: copy only, don't paste
                        } else spEnter();
                        ev.accepted = true;
                    }
                }
                function spToggleSection(name) {
                    var o = {};
                    for (var k in spExpanded) o[k] = spExpanded[k];
                    o[name] = !o[name];
                    spExpanded = o;
                }
                // gutter for check marks when any entry of the open menu has one
                readonly property bool menuLead: {
                    for (var i = 0; i < menuModel.length; i++) if (menuModel[i].checked !== undefined) return true;
                    return false;
                }
                Connections {
                    target: root
                    function onActiveWinChanged() { if (ui.isMenu) ui.menuModel = root.menuModelFor(ui.pop); }
                }
                // bounding box of all glass that is on screen right now (popovers, notification popups) + a refraction margin
                readonly property rect glassRect: {
                    var items = [overflowPop, servicePop, menuPop, cc, cal, wifiPop, btPop, trayPop, notifPop, toastArea, volPop, kbPop], x0 = 1e9, y0 = 1e9, x1 = -1e9, y1 = -1e9, any = false;
                    for (var i = 0; i < items.length; i++) {
                        var it = items[i];
                        if (!it.visible) continue;
                        any = true;
                        x0 = Math.min(x0, it.x); y0 = Math.min(y0, it.y); x1 = Math.max(x1, it.x + it.width); y1 = Math.max(y1, it.y + it.height);
                    }
                    return any ? Qt.rect(x0 - 64, y0 - 64, x1 - x0 + 128, y1 - y0 + 128) : Qt.rect(0, 0, 0, 0);
                }
                readonly property bool isMenu: ["apple", "app", "file", "edit", "view", "window", "help"].indexOf(pop) >= 0
                readonly property bool networkEmbedded: (pop === "wifi" && wifiPop.parent === cc) || (pop === "bt" && btPop.parent === cc)
                readonly property bool anyVisible: overflowPop.visible || servicePop.visible || menuPop.visible || cc.visible || cal.visible || wifiPop.visible || btPop.visible || trayPop.visible || notifPop.visible || toastArea.visible || volPop.visible || kbPop.visible
                onAnyVisibleChanged: root.popCount += (anyVisible ? 1 : -1)
                onPopChanged: {
                    if (pop !== "spot") spCloseActions();
                    if (pop === "") { anchorType = ""; anchorOverflow = false; }
                    if (["stats", "wifijoin", "focus", "awake", "night", "btpair", "record", "battery", "airplay"].indexOf(pop) >= 0)
                        servicePop.contentName = pop;
                    if (pop !== "" && pop !== "spot") {
                        root.interactionScreen = win.modelData.name;
                        root.popupOwner = win.modelData.name;
                        root.activeControl = pop;
                        Qt.callLater(() => { if (["", "spot", "wifijoin", "btpair", "airplay"].indexOf(ui.pop) < 0) ui.forceActiveFocus(); });
                    } else if (root.popupOwner === win.modelData.name) { root.popupOwner = ""; root.activeControl = ""; }
                    if (pop !== "" && pop !== "spot") toneT.restart();
                    if (pop === "spot" && ui.toastScreen) root.measureTone(win.modelData.x + ui.width / 2 - 320, win.modelData.y + ui.height * 0.4 - 30, 640, 60);
                    armed = "";
                    wifiPrompt = "";
                    spHoverLabel = "";
                    if (pop !== "cc") ccEdit = false;
                    root.notifOpen = (pop === "notif");
                    if (root.notifOpen) root.notifUnread = 0;
                    if (pop === "wifi") { root.wifi.error = ""; root.scanWifi(); root.refreshConnections(); }
                    if (pop === "bt") { root.bluetooth.error = ""; root.refreshBt(); }
                    if (pop === "spot") {
                        spMode = "home"; spQuery = ""; spSel = 0; spExpanded = ({}); clipMenu = false;
                        spInput.text = ""; appsInput.text = ""; clipInput.text = ""; emojiInput.text = "";
                        spFocusTimer.restart();
                    }
                }
                Connections {
                    target: root
                    function onSpotRequestChanged() {
                        var fm = Niri.focusedMonitor;
                        if (!(!fm || fm.name === win.modelData.name || Quickshell.screens.length === 1)) return;
                        var want = root.spotWant;
                        if (ui.pop === "spot") {
                            if (want === "home" || want === ui.spMode) ui.pop = "";    // same key again closes it
                            else ui.spSetMode(want);
                        } else {
                            ui.spReqCalm = (want === "clip" || want === "emoji");
                            ui.openPop("spot", 0);
                            if (want !== "home") ui.spSetMode(want);
                        }
                    }
                }

                Connections {
                    target: root
                    function onNotifPopRequest(open) {
                        if (!ui.toastScreen) return;
                        if (open) ui.openPop("notif", ui.width); else if (ui.pop === "notif") ui.pop = "";
                    }
                }
                function openPop(name, x, fromOverflow, sourceType) {
                    if (pop === name) { pop = ""; return; }
                    if (name === "spot") { spCalm = spReqCalm; spReqCalm = false; }
                    anchorType = sourceType || typeForPopup(name);
                    anchorOverflow = !!fromOverflow;
                    if (!anchorOverflow && (!barBg.plan.byType[anchorType] || barBg.plan.byType[anchorType].width <= 0)) anchorType = "";
                    menuX = x;
                    if (["apple", "app", "file", "edit", "view", "window", "help"].indexOf(name) >= 0) root.refreshActive();
                    if (["apple", "app", "file", "edit", "view", "window", "help"].indexOf(name) >= 0) menuModel = root.menuModelFor(name);
                    if (name === "cal") { var d = new Date(); calYear = d.getFullYear(); calMonth = d.getMonth(); }
                    pop = name;
                    updateAnchor();
                }
                function hoverPop(name, x) {
                    if (!isMenu || name === pop) return;
                    anchorType = typeForPopup(name); anchorOverflow = false;
                    menuX = x;
                    menuModel = root.menuModelFor(name);
                    pop = name; updateAnchor();
                }
                function calCells() {
                    var first = new Date(calYear, calMonth, 1);
                    var off = (first.getDay() - (root.weekStartsMonday ? 1 : 0) + 7) % 7;
                    var today = new Date(), out = [];
                    for (var i = 0; i < 42; i++) {
                        var d = new Date(calYear, calMonth, 1 - off + i);
                        out.push({ n: d.getDate(), cur: d.getMonth() === calMonth,
                                   today: d.getFullYear() === today.getFullYear() && d.getMonth() === today.getMonth() && d.getDate() === today.getDate() });
                    }
                    return out;
                }
                function shiftMonth(delta) {
                    var d = new Date(calYear, calMonth + delta, 1);
                    calYear = d.getFullYear(); calMonth = d.getMonth();
                }
                readonly property var calData: { clock.date; return calCells(); }

                // ── Liquid Glass backdrop: wallpaper + live windows behind the popovers, in screen coordinates ──
                // The backdrop (wallpaper + one capture per window) used to be built from scratch every time a popover opened,
                // which is the "wallpaper first, windows a moment later" delay. It now stays alive, so a popover opens on
                // ready-made, current window pixels.
                Loader {
                    id: glassBackdrop
                    active: root.liquidActive
                    sourceComponent: backdropComp
                    onLoaded: item.region = Qt.binding(function () { return ui.glassRect; })
                }
                // a moment after a popover starts opening (its rect is known), measure what's behind it
                Timer {
                    id: toneT; interval: 20
                    onTriggered: {
                        var r = ui.glassRect;
                        if (r.width <= 0) return;
                        root.measureTone(win.modelData.x + r.x + 64, win.modelData.y + r.y + 64, r.width - 128, r.height - 128);
                    }
                }
                readonly property Item glassSrc: glassBackdrop.item

                // keeps the (otherwise unseen) backdrop rendering so its window captures stay valid; draws one 1%-opaque pixel
                ShaderEffectSource {
                    sourceItem: glassBackdrop.item
                    hideSource: true
                    live: true
                    width: 1; height: 1
                    opacity: 0.01
                    sourceRect: Qt.rect(0, 0, 1, 1)
                }
                Component {
                    id: backdropComp
                    BackdropTexture {
                        id: bd
                        property bool hostShown: true      // false while the window hosting this backdrop is hidden (set by its Loader)
                        property rect region: Qt.rect(0, 0, 0, 0)      // the glass that is on screen right now (set by its Loader); windows behind it stay live while recording
                        x: 0; y: 0
                        width: win.modelData.width
                        height: win.modelData.height

                        Rectangle {
                            z: -3
                            anchors.fill: parent
                            gradient: Gradient {
                                orientation: Gradient.Horizontal
                                GradientStop { position: 0.0; color: "#2f6bff" }
                                GradientStop { position: 0.5; color: "#b44cff" }
                                GradientStop { position: 1.0; color: "#ff8a3d" }
                            }
                        }
                        Image {
                            z: -2
                            anchors.fill: parent
                            visible: status === Image.Ready
                            source: root.fileUrl(root.wallpaperFor(win.modelData.name))
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            sourceSize.width: bd.width
                            smooth: true
                        }

                        // the desktop widgets (they sit on the desktop layer, below every window), drawn from the same
                        // content as the real ones, so the glass shows them under the live windows
                        WidgetModel { id: mirrorWidgets; rows: root.hub && root.hub.widgets && root.hub.widgets.widgetsEnabled ? root.hub.widgets.rowsForOutput(win.modelData.name) : [] }
                        Repeater {
                            model: mirrorWidgets
                            delegate: Item {
                                id: mw
                                required property string wid
                                required property string wtype
                                required property string wstyle
                                required property string wsize
                                required property string wmode
                                required property string wappearance
                                required property string wactivity
                                required property string wbatteries
                                required property string wtimer
                                required property string wimage
                                required property real wx
                                required property real wy
                                z: -1
                                x: wx; y: wy
                                width: root.hub.widgets.dims(wsize)[0]
                                height: root.hub.widgets.dims(wsize)[1]
                                WidgetVisual {
                                    objectName: "widgetMirror_" + mw.wid
                                    anchors.fill: parent
                                    host: root.hub.widgets
                                    instanceId: mw.wid; mirror: true
                                    renderActive: animationsEnabled && root.hub.widgets.outputActive(win.modelData.name)
                                    animationsEnabled: bd.hostShown && bd.region.width > 0
                                        && mw.x < bd.region.x + bd.region.width && mw.x + mw.width > bd.region.x
                                        && mw.y < bd.region.y + bd.region.height && mw.y + mw.height > bd.region.y
                                    wtype: mw.wtype; wstyle: mw.wstyle; wsize: mw.wsize; wmode: mw.wmode
                                    wappearance: mw.wappearance
                                    wactivity: mw.wactivity
                                    wbatteries: mw.wbatteries
                                    wtimer: mw.wtimer
                                    wimage: mw.wimage
                                    sx: mw.x; sy: mw.y
                                    sname: win.modelData.name; sw: win.modelData.width; sh: win.modelData.height
                                }
                            }
                        }

                        ListModel { id: wm }
                        Repeater {
                            model: wm
                            delegate: Item {
                                id: gw
                                required property string addr
                                required property real wx
                                required property real wy
                                required property real ww
                                required property real wh
                                required property real wz
                                required property bool gone      // window closed: capture is released first, the item is swept shortly after
                                x: wx; y: wy; width: ww; height: wh; z: wz
                                readonly property var tl: { if (!root.hub || gone) return null; var t = root.hub.tlTick; return root.hub.tlFor(addr); }
                                // behind the glass that is on screen right now (popover / panel + refraction margin)?
                                readonly property bool onGlass: bd.region.width > 0 && x < bd.region.x + bd.region.width && x + width > bd.region.x
                                                                && y < bd.region.y + bd.region.height && y + height > bd.region.y
                                NiriPreview {
                                    id: sv
                                    anchors.fill: parent
                                    captureSource: gw.tl
                                    // While a screen recording / screen share runs the window captures sit out (root.captureQuiet). `hush` follows it
                                    // with a random 0.6 s spread, so dozens of captures never start or stop in the same instant (that burst, with a
                                    // recorder pulling frames at the same time, is what the compositor choked on).
                                    property bool hush: root.captureQuiet
                                    Connections {
                                        target: root
                                        function onCaptureQuietChanged() { hushT.interval = 20 + Math.random() * 600; hushT.restart(); }
                                    }
                                    Timer { id: hushT; onTriggered: sv.hush = root.captureQuiet }
                                    // REAL-TIME: with glassRealtime every capture stays live all the time, so a popover opens on
                                    // frames that are already current and nothing is torn down / restarted when it opens (the restart
                                    // is what used to show the bare wallpaper first). Backdrops that live in a window which is
                                    // hidden right now (Spotlight, switcher, ...) are only kept warm with slow single captures.
                                    // While recording only the windows behind visible glass stay live (so the glass is real-time exactly where you see it,
                                    // e.g. a video behind the Control Center), every other window sits out.
                                    live: !gw.gone && !root.captureHeld && bd.hostShown && gw.onGlass && !sv.hush && (root.glassRealtime || ui.anyVisible || spotWin.openish || swWin.visible || wpWin.visible)
                                    onCaptureSourceChanged: {
                                        // a brand-new capture grabs its first frame immediately instead of waiting for the timer
                                        // (a short delay: asking before the capture context exists only logged "no recording context is ready")
                                        if (captureSource !== null && !live && !sv.hush && !root.captureHeld) firstShot.restart();
                                    }
                                    Timer {
                                        id: firstShot
                                        interval: 90
                                        onTriggered: { if (sv.captureSource !== null && !sv.live && typeof sv.captureFrame === "function") sv.captureFrame(); }
                                    }
                                    // single captures: hidden backdrops stay warm once a second (their window goes live the moment it opens);
                                    // while recording only a backdrop that is actually on screen refreshes, slowly
                                    Timer {
                                        interval: sv.hush ? 1500 : (bd.hostShown ? 250 : 1000); repeat: true
                                        running: !root.captureHeld && !sv.live && sv.captureSource !== null && gw.onGlass && bd.hostShown && !sv.hush
                                        onTriggered: { if (typeof sv.captureFrame === "function") sv.captureFrame(); }
                                    }
                                }
                            }
                        }

                        function sync() {
                            var mon = null, i;
                            for (i = 0; i < root.monData.length; i++)
                                if (root.monData[i].name === win.modelData.name) mon = root.monData[i];
                            if (!mon) return;
                            var ws = [mon.activeWorkspace ? mon.activeWorkspace.id : -999];
                            if (mon.specialWorkspace && mon.specialWorkspace.id !== 0) ws.push(mon.specialWorkspace.id);
                            var zoneBottom = bd.height;
                            var want = {};
                            var cs = root.glassClients;
                            for (var c = 0; c < cs.length; c++) {
                                var cl = cs[c];
                                if (!cl.mapped || cl.hidden || cl.monitor !== mon.id || ws.indexOf(cl.workspace.id) < 0) continue;
                                var x = cl.at[0] - mon.x, y = cl.at[1] - mon.y, w = cl.size[0], h = cl.size[1];
                                if (x + w <= 0 || x >= bd.width || y + h <= 0 || y >= zoneBottom) continue;
                                var z = cl.floating ? 100 - Math.min(cl.focusHistoryID, 90) : 0;
                                want[cl.address] = { addr: cl.address, wx: x, wy: y, ww: w, wh: h, wz: z, gone: false };
                            }
                            for (var j = wm.count - 1; j >= 0; j--) {
                                var a = wm.get(j).addr;
                                if (want[a] === undefined) { if (!wm.get(j).gone) { wm.setProperty(j, "gone", true); sweep.restart(); } }
                                else { wm.set(j, want[a]); delete want[a]; }
                            }
                            for (var k in want) wm.append(want[k]);
                        }
                        // a closed window first lets go of its capture (gone → captureSource null), the item itself is removed a moment later
                        Timer {
                            id: sweep
                            interval: 600
                            onTriggered: { for (var q = wm.count - 1; q >= 0; q--) if (wm.get(q).gone) wm.remove(q); }
                        }
                        Connections {
                            target: root
                            function onGlassClientsChanged() { bd.sync(); }
                            function onMonDataChanged() { bd.sync(); }
                        }
                        Component.onCompleted: sync()
                    }
                }

                Item {
                    id: maskItem
                    x: 0; y: 0
                    width: ui.width
                    height: (ui.pop !== "" && ui.pop !== "spot") ? ui.height : root.barHeight
                }

                // Liquid Glass menu bar strip: the bar itself refracts the live backdrop (wallpaper + windows), like the popovers.
                // Settings → Menu Bar → "Liquid Glass bar". Sits under every bar item.
                LGlass {
                    id: barGlassStrip
                    visible: root.barGlass && root.liquidActive
                    x: 0; y: 0
                    width: ui.width
                    height: root.barHeight
                    backdrop: ui.glassSrc
                    shaderUrl: root.glassShaderUrl
                    liquid: root.liquidActive
                    dark: root.effDark

                    cornerR: 0
                    tint: root.glassOpacity * 0.6
                    thickness: 16
                    strength: 0.9 * root.glassLiquid
                    rim: root.glassRim
                    grain: root.glassGrain
                    blur: root.glassBlur
                    debug: root.glassDebug
                    onShaderError: root.glassState = "failed"
                }

                // click-away layer (under the popovers and the bar)
                MouseArea {
                    anchors.fill: parent
                    z: 5
                    visible: ui.pop !== "" && ui.pop !== "spot"
                    acceptedButtons: Qt.AllButtons
                    onPressed: ui.pop = ""
                }

                // ═════════ the bar itself ═════════
                Rectangle {
                    id: barBg
                    visible: root.barEnabled
                    z: 20
                    x: 0; y: 0
                    width: ui.width
                    height: root.barHeight
                    color: "transparent"      // Tahoe: the bar is fully clear, no fill and no border on any side
                    MouseArea { anchors.fill: parent; onClicked: ui.pop = "" }

                    // All blocks use one allocation in unscaled logical bar units.
                    readonly property string layoutJson: JSON.stringify(root.barLayout.layoutFor(Niri.monitorFor(perScreen.modelData) || {name: perScreen.modelData.name}))
                    readonly property var layout: JSON.parse(layoutJson)
                    readonly property bool trayWanted: layout.some(item => item.type === "tray" && item.enabled)
                    onLayoutJsonChanged: if (ui.anchorType !== "") ui.pop = ""
                    FontMetrics { id: barMetrics; font.family: screenPal.fam; font.pixelSize: 13 }
                    FontMetrics { id: barBoldMetrics; font.family: screenPal.fam; font.pixelSize: 13; font.bold: true }
                    readonly property var measurements: ({
                        appMenus: {preferred: root.menuTitles.filter(item => item.id !== "apple").reduce((sum, item) => sum + (item.bold ? barBoldMetrics : barMetrics).advanceWidth(item.label) + 20, 0), forms: [root.menuTitles.filter(item => item.id !== "apple").reduce((sum, item) => sum + (item.bold ? barBoldMetrics : barMetrics).advanceWidth(item.label) + 20, 0), 100]},
                        workspaces: {preferred: root.workspaceIdsFor(perScreen.modelData.name).length * 22, forms: [root.workspaceIdsFor(perScreen.modelData.name).length * 22, 22]},
                        monitoring: {available: root.statsMetrics.length > 0, preferred: root.statsMetrics.length * 28 + 8, forms: [root.statsMetrics.length * 28 + 8, root.statsMetrics.length * 22 + 4, 26]},
                        tray: {preferred: trayWanted ? SystemTray.items.values.length * 26 : 0, available: trayWanted && SystemTray.items.values.length > 0},
                        keyboard: {available: root.kbLayouts.length !== 1},
                        battery: {available: root.hasBattery, preferred: batRow.implicitWidth + 14},
                        privacy: {available: root.privacyAny, preferred: root.privacyDots.length * 10},
                        controlCenter: {available: root.ccEnabled},
                        clock: {preferred: barMetrics.advanceWidth(root.clockText) + 16, forms: [barMetrics.advanceWidth(root.clockText) + 16, barMetrics.advanceWidth(Language.I18n.formatTime(clock.date, root.use24h ? "HH:mm" : "h:mm AP")) + 16]}
                    })
                    readonly property var plan: BarLayout.solve(layout, root.barLayout.catalog, measurements, width / root.barWidgetScale)
                    function reportFrame() {
                        var items = {};
                        Object.keys(plan.items).forEach(key => {
                            var item = plan.items[key];
                            items[key] = {type: item.type, x: item.x * root.barWidgetScale, width: item.width * root.barWidgetScale, mode: item.mode};
                        });
                        var next = Object.assign({}, root.barFrames);
                        next[perScreen.modelData.name] = {width: width, height: height, scale: root.barWidgetScale, items: items, overflow: plan.overflow.map(item => item.type), overflowX: plan.overflowX * root.barWidgetScale};
                        if (JSON.stringify(next) !== JSON.stringify(root.barFrames)) root.barFrames = next;
                    }
                    onPlanChanged: { Qt.callLater(ui.updateAnchor); Qt.callLater(reportFrame); }
                    Component.onDestruction: {
                        var next = Object.assign({}, root.barFrames); delete next[perScreen.modelData.name]; root.barFrames = next;
                    }
                    Component { id: barMenuEntry;
                        Item {
                            id: mt
                            required property var modelData
                            readonly property bool open: ui.pop === modelData.id
                            width: modelData.id === "apple" ? 30 : appSlot.placement.mode > 0 ? appSlot.width : tl.implicitWidth + 20
                            height: 28
                            Rectangle {
                                anchors.centerIn: parent
                                width: parent.width - 2
                                height: parent.height - 6
                                radius: 6
                                color: mt.open ? screenPal.hover : "transparent"
                            }
                            Glyph {
                                visible: mt.modelData.id === "apple" && root.barLogoMode === "arch"
                                anchors.centerIn: parent
                                width: 15; height: 15
                                kind: "arch"
                                color: screenPal.fg
                            }
                            Image {
                                visible: mt.modelData.id === "apple" && root.barLogoMode === "apple"
                                anchors.centerIn: parent
                                width: 15; height: 15
                                source: root.darkMode ? Qt.resolvedUrl("apple-logo-white.svg") : Qt.resolvedUrl("apple-logo-black.svg")
                                sourceSize: Qt.size(128, 160)
                                fillMode: Image.PreserveAspectFit
                                smooth: true
                                mipmap: true
                            }
                            Image {
                                id: customBarLogo
                                visible: mt.modelData.id === "apple" && root.barLogoMode === "custom" && root.barCustomLogoUrl !== ""
                                anchors.centerIn: parent
                                width: 17; height: 17
                                source: root.barCustomLogoUrl
                                sourceSize: Qt.size(64, 64)
                                fillMode: Image.PreserveAspectFit
                                smooth: true
                                mipmap: true
                            }
                            Glyph {
                                visible: mt.modelData.id === "apple" && root.barLogoMode === "custom"
                                && (root.barCustomLogoUrl === "" || customBarLogo.status === Image.Error)
                                anchors.centerIn: parent
                                width: 15; height: 15
                                kind: "arch"
                                color: screenPal.fg
                            }
                            Text {
                                id: tl
                                visible: mt.modelData.id !== "apple"
                                anchors.centerIn: parent
                                width: mt.modelData.id !== "apple" && appSlot.placement.mode > 0 ? Math.max(0, mt.width - 30) : implicitWidth
                                elide: Text.ElideRight
                                text: mt.modelData.label
                                color: screenPal.fg
                                font.family: screenPal.fam
                                font.pixelSize: 13
                                font.weight: mt.modelData.bold ? Font.Bold : Font.Normal
                            }
                            Text {
                                visible: mt.modelData.id === "app" && appSlot.placement.mode > 0
                                anchors.right: parent.right; anchors.rightMargin: 5; anchors.verticalCenter: parent.verticalCenter
                                text: "⌄"; color: screenPal.fg; font.pixelSize: 12
                            }
                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: ui.openPop(mt.modelData.id === "app" && appSlot.placement.mode > 0 ? "appmenus" : mt.modelData.id, mt.mapToItem(ui, 0, 0).x, false, mt.modelData.id === "apple" ? "appleMenu" : "appMenus")
                                onEntered: ui.hoverPop(mt.modelData.id, mt.mapToItem(ui, 0, 0).x)
                            }
                        }
                    }
                    Item {
                        id: barContent
                        width: barBg.width / root.barWidgetScale; height: 28
                        y: (barBg.height - height * scale) / 2
                        scale: root.barWidgetScale; transformOrigin: Item.TopLeft
                        BarSlot { id: appleSlot; blockType: "appleMenu"; plan: barBg.plan
                            Row { height: 28; Repeater { model: root.menuTitles.filter(item => item.id === "apple"); delegate: barMenuEntry } }
                        }
                        BarSlot { id: appSlot; blockType: "appMenus"; plan: barBg.plan
                            Row { height: 28; Repeater { model: root.menuTitles.filter(item => item.id !== "apple" && (appSlot.placement.mode === 0 || item.id === "app")); delegate: barMenuEntry } }
                        }
                        BarSlot { id: wsSlot; blockType: "workspaces"; plan: barBg.plan
                            Row {
                                id: wsRow
                                visible: true


                                height: 28
                                transformOrigin: Item.Center

                                spacing: 0
                                readonly property var mon: Niri.monitorFor(perScreen.modelData)
                                readonly property double activeId: mon && mon.activeWorkspace ? mon.activeWorkspace.id : (Niri.focusedWorkspace ? Niri.focusedWorkspace.id : -1)
                                Repeater {
                                    model: wsSlot.placement.mode > 0 ? [wsRow.activeId].filter(id => id >= 0) : root.workspaceIdsFor(perScreen.modelData.name)
                                    delegate: Item {
                                        id: wsi
                                        required property var modelData
                                        readonly property bool cur: wsRow.activeId === modelData
                                        readonly property bool busy: root.wsOccupied(modelData)
                                        width: 22; height: 28
                                        Rectangle {
                                            anchors.centerIn: parent
                                            width: parent.width - 2
                                            height: parent.height - 6
                                            radius: 6
                                            color: wsi.cur ? screenPal.hover : "transparent"
                                            opacity: wsi.cur || wsMa.containsMouse ? 1 : 0
                                            Behavior on opacity { NumberAnimation { duration: 140 } }
                                        }
                                        Text {
                                            anchors.centerIn: parent
                                            text: Niri.workspaceLabel(wsi.modelData)
                                            color: wsi.cur ? screenPal.fg : (wsi.busy ? screenPal.fg2 : screenPal.fg3)
                                            font.family: screenPal.fam
                                            font.pixelSize: 13
                                            font.weight: wsi.cur ? Font.DemiBold : Font.Normal
                                        }
                                        MouseArea {
                                            id: wsMa
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            onClicked: { ui.pop = ""; root.focusWorkspace("" + wsi.modelData); }
                                        }
                                    }
                                }
                                WheelHandler {
                                    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                                    onWheel: event => root.focusWorkspace(event.angleDelta.y > 0 ? "e-1" : "e+1")
                                }
                            }
                        }
                        BarSlot { id: statsSlot; blockType: "monitoring"; plan: barBg.plan
                            SystemStatsBar {
                                id: statsBar
                                controller: root.stats; foreground: screenPal.fg
                                accent: screenPal.accent; fontFamily: screenPal.fam
                                active: ui.pop === "stats"
                                tooltipsEnabled: ui.pop === ""
                                property bool counted: false
                                readonly property bool subscribed: visible && root.barEnabled
                                function subscribe() {
                                    if (counted !== subscribed) { root.statsConsumers += subscribed ? 1 : -1; counted = subscribed; }
                                }
                                onSubscribedChanged: subscribe()
                                Component.onCompleted: subscribe()
                                Component.onDestruction: if (counted) root.statsConsumers--
                                metrics: root.statsMetrics
                                memoryPercent: root.statsMemoryPercent
                                appearance: root.activityPreferences.values
                                budget: statsSlot.width
                                onClicked: { var p = mapToItem(ui, width / 2, 0); ui.openPop("stats", p.x); }
                            }
                        }
                        BarSlot { id: traySlot; blockType: "tray"; plan: barBg.plan
                            Row { height: 28;
                                Repeater {
                                    model: traySlot.visible ? SystemTray.items : null
                                    delegate: Item {
                                        id: tray
                                        required property var modelData
                                        width: 26; height: 28
                                        Rectangle {
                                            anchors.centerIn: parent
                                            width: parent.width - 2
                                            height: parent.height - 6
                                            radius: 6
                                            color: (ui.pop === "tray" && ui.trayItem === tray.modelData) ? screenPal.hover : "transparent"
                                        }
                                        Image {
                                            anchors.centerIn: parent
                                            width: 16; height: 16
                                            source: tray.modelData.icon
                                            sourceSize: Qt.size(32, 32)
                                            fillMode: Image.PreserveAspectFit
                                            smooth: true
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                                            onClicked: mouse => {
                                                var p = tray.mapToItem(ui, 0, 0);
                                                if (mouse.button === Qt.RightButton || (mouse.button === Qt.LeftButton && tray.modelData.onlyMenu))
                                                ui.openTray(tray.modelData, p.x);
                                                else if (mouse.button === Qt.MiddleButton)
                                                tray.modelData.secondaryActivate();
                                                else
                                                tray.modelData.activate();
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        BarSlot { id: btSlot; blockType: "bluetooth"; plan: barBg.plan
                            Item {
                                id: btBtn
                                objectName: "barBluetoothButton"
                                width: 26; height: 28
                                Rectangle {
                                    anchors.centerIn: parent
                                    width: parent.width - 2; height: parent.height - 6; radius: 6
                                    color: ui.pop === "bt" ? screenPal.hover : "transparent"
                                }
                                Glyph { anchors.centerIn: parent; width: 15; height: 15; kind: "bluetooth"; color: root.btOn && root.btConnected > 0 ? screenPal.fg : screenPal.fg2 }
                                MouseArea { anchors.fill: parent; onClicked: ui.openPop("bt", btBtn.mapToItem(ui, 0, 0).x + btBtn.width / 2) }
                            }
                        }
                        BarSlot { id: volSlot; blockType: "volume"; plan: barBg.plan
                            Item {
                                id: volBtn
                                width: 28; height: 28
                                Rectangle {
                                    anchors.centerIn: parent
                                    width: parent.width - 2; height: parent.height - 6; radius: 6
                                    color: ui.pop === "vol" ? screenPal.hover : "transparent"
                                }
                                Glyph { anchors.centerIn: parent; width: 16; height: 16; kind: "speaker"; level: root.volLevel; color: screenPal.fg }
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: ui.openPop("vol", volBtn.mapToItem(ui, 0, 0).x + volBtn.width / 2)
                                    onWheel: wheel => root.setVolume(root.volume + (wheel.angleDelta.y > 0 ? 0.03 : -0.03))
                                }
                            }
                        }
                        BarSlot { id: kbSlot; blockType: "keyboard"; plan: barBg.plan
                            Item {
                                id: kbBtn
                                width: 34; height: 28
                                Rectangle {
                                    anchors.centerIn: parent
                                    width: parent.width - 2; height: parent.height - 6; radius: 6
                                    color: (ui.pop === "kb" || kbMouse.containsMouse) ? screenPal.hover : "transparent"
                                }
                                Text {
                                    anchors.centerIn: parent
                                    text: root.keyboardLayout
                                    color: screenPal.fg
                                    font.family: screenPal.fam; font.pixelSize: 12; font.weight: Font.DemiBold
                                }
                                MouseArea {
                                    id: kbMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                                    onClicked: mouse => {
                                        if (mouse.button === Qt.RightButton) ui.openPop("kb", kbBtn.mapToItem(ui, 0, 0).x + kbBtn.width / 2);
                                        else root.cycleKeyboardLayout(1);
                                    }
                                    onWheel: wheel => root.cycleKeyboardLayout(wheel.angleDelta.y > 0 ? -1 : 1)
                                }
                            }
                        }
                        BarSlot { id: batterySlot; blockType: "battery"; plan: barBg.plan
                            Item {
                                id: batteryButton
                                objectName: "batteryButton"
                                visible: root.hasBattery
                                width: root.hasBattery ? batRow.width + 14 : 0; height: 28
                                Row {
                                    id: batRow
                                    anchors.centerIn: parent
                                    spacing: 5
                                    Text {
                                        visible: root.showBatteryPercent
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: root.batPct + "%"
                                        color: screenPal.fg
                                        font.family: screenPal.fam; font.pixelSize: 12
                                    }
                                    Item {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 25; height: 12
                                        Rectangle {
                                            id: bbody
                                            width: 22; height: 12; radius: 3.5
                                            color: "transparent"
                                            border.width: 1
                                            border.color: screenPal.fg2
                                            Rectangle {
                                                x: 1.5; y: 1.5
                                                width: Math.max(2, (parent.width - 3) * Math.min(1, root.batPct / 100))
                                                height: parent.height - 3
                                                radius: 2
                                                color: root.charging ? "#30D158" : (root.batPct <= 15 ? "#FF453A" : screenPal.fg)
                                            }
                                        }
                                        Rectangle { x: 23; y: 4; width: 2; height: 4; radius: 1; color: screenPal.fg2 }
                                        Glyph {
                                            visible: root.charging
                                            anchors.centerIn: bbody
                                            width: 9; height: 9
                                            kind: "bolt"
                                            color: screenPal.dark ? "#111" : "#fff"
                                        }
                                    }
                                }
                                Controls.ToolTip {
                                    id: batteryTip
                                    visible: batteryMouse.containsMouse && ui.pop === ""
                                    delay: 650
                                    text: root.batPct + "% · " + root.battery.remaining + "\n" + root.power.label(root.power.profile)
                                    background: Rectangle { radius: 8; color: screenPal.dark ? "#303035" : "#fafafb"; border.color: screenPal.dark ? "#55555b" : "#d5d5da" }
                                    contentItem: Text { text: batteryTip.text; color: screenPal.fg; font.family: screenPal.fam; font.pixelSize: 12 }
                                }
                                MouseArea {
                                    id: batteryMouse; anchors.fill: parent; hoverEnabled: true
                                    onClicked: { root.power.refresh(); ui.openPop("battery", batteryButton.mapToItem(ui, 0, 0).x + batteryButton.width / 2); }
                                }
                            }
                        }
                        BarSlot { id: bellSlot; blockType: "notifications"; plan: barBg.plan
                            Item {
                                id: bellBtn
                                width: 28; height: 28
                                Rectangle {
                                    anchors.centerIn: parent
                                    width: parent.width - 2; height: parent.height - 6; radius: 6
                                    color: ui.pop === "notif" ? screenPal.hover : "transparent"
                                }
                                Glyph { anchors.centerIn: parent; width: 16; height: 16; kind: "bell"; color: root.notifDnd ? screenPal.fg2 : screenPal.fg }
                                Rectangle {
                                    visible: root.notifUnread > 0 && !root.notifDnd
                                    x: parent.width / 2 + 2; y: parent.height / 2 - 8
                                    width: 7; height: 7; radius: 3.5
                                    color: "#FF453A"
                                }
                                MouseArea { anchors.fill: parent; onClicked: ui.openPop("notif", bellBtn.mapToItem(ui, width / 2, 0).x) }
                            }
                        }
                        BarSlot { id: wifiSlot; blockType: "wifi"; plan: barBg.plan
                            Item {
                                id: wifiBtn
                                objectName: "barWifiButton"
                                width: 28; height: 28
                                Rectangle {
                                    anchors.centerIn: parent
                                    width: parent.width - 2; height: parent.height - 6; radius: 6
                                    color: ui.pop === "wifi" ? screenPal.hover : "transparent"
                                }
                                Glyph { anchors.centerIn: parent; width: 16; height: 16; kind: root.showEthernet ? "ethernet" : "wifi"; level: root.wifiOn ? (root.wifiLevel || 1) : 3; flag: !root.wifiOn && !root.showEthernet; color: (root.wifiOn || root.showEthernet) ? screenPal.fg : screenPal.fg2 }
                                MouseArea { anchors.fill: parent; onClicked: ui.openPop("wifi", wifiBtn.mapToItem(ui, 0, 0).x) }
                            }
                        }
                        BarSlot { id: ccSlot; blockType: "controlCenter"; plan: barBg.plan
                            Item {
                                id: ccBtn
                                objectName: "barControlCenterButton"
                                width: 30; height: 28
                                Rectangle {
                                    anchors.centerIn: parent
                                    width: parent.width - 2; height: parent.height - 6; radius: 6
                                    color: ui.pop === "cc" ? screenPal.hover : "transparent"
                                }
                                Glyph { x: 7; anchors.verticalCenter: parent.verticalCenter; width: 16; height: 16; kind: "cc"; color: screenPal.fg }
                                MouseArea { anchors.fill: parent; onClicked: ui.openPop("cc", ccBtn.mapToItem(ui, width / 2, 0).x) }
                            }
                        }
                        BarSlot { id: clockSlot; blockType: "clock"; plan: barBg.plan
                            Item {
                                id: clockBtn
                                width: clockSlot.width
                                height: 28
                                Rectangle {
                                    anchors.centerIn: parent
                                    width: parent.width - 2; height: parent.height - 6; radius: 6
                                    color: ui.pop === "cal" ? screenPal.hover : "transparent"
                                }
                                Text {
                                    id: clockText
                                    anchors.centerIn: parent
                                    text: clockSlot.placement.mode > 0 ? Language.I18n.formatTime(clock.date, root.use24h ? "HH:mm" : "h:mm AP") : root.clockText
                                    color: screenPal.fg
                                    font.family: screenPal.fam
                                    font.pixelSize: 13
                                }
                                MouseArea { anchors.fill: parent; onClicked: ui.openPop("cal", clockBtn.mapToItem(ui, width / 2, 0).x) }
                            }
                        }
                        BarSlot { id: searchSlot; blockType: "search"; plan: barBg.plan
                            Item {
                                width: 28; height: 28
                                Glyph { anchors.centerIn: parent; width: 15; height: 15; kind: "search"; color: screenPal.fg }
                                MouseArea { anchors.fill: parent; onClicked: { if (root.launcher !== "") { ui.pop = ""; root.search(); } else ui.openPop("spot", 0); } }
                            }
                        }
                        BarSlot { id: privacySlot; blockType: "privacy"; plan: barBg.plan
                            Item {
                                width: privacySlot.width; height: 28
                                Row { anchors.centerIn: parent; spacing: 3
                                    Repeater { model: root.privacyDots; delegate: Rectangle { required property string modelData; width: 7; height: 7; radius: 3.5; color: modelData; border.width: .5; border.color: "#59000000" } }
                                }
                                MouseArea { anchors.fill: parent; onClicked: ui.openPop("cc", privacySlot.mapToItem(ui, width / 2, 0).x, false, "privacy") }
                            }
                        }
                        Item {
                            id: overflowButton
                            x: barBg.plan.overflowX; width: barBg.plan.overflowWidth; height: 28; visible: width > 0
                            Text { anchors.centerIn: parent; text: "•••"; color: screenPal.fg; font.family: screenPal.fam; font.pixelSize: 12 }
                            MouseArea { anchors.fill: parent; onClicked: ui.openPop("overflow", overflowButton.mapToItem(ui, width / 2, 0).x) }
                        }
                    }
                }

                Rectangle {
                    id: overflowPop
                    z: 11; width: Math.min(300, ui.width - 12)
                    height: Math.min(overflowList.contentHeight + 20, ui.height - root.barHeight - 24)
                    x: ui.popupX(width, 1, Item.TopLeft)
                    y: root.barHeight + 6; radius: 14
                    color: pal.dark ? "#f024252b" : "#f0fafafb"
                    border.color: pal.dark ? "#55555b" : "#d5d5da"
                    visible: ui.pop === "overflow" || ui.pop === "appmenus"
                    MouseArea { anchors.fill: parent }
                    ListView {
                        id: overflowList; anchors.fill: parent; anchors.margins: 10
                        clip: true; model: ui.overflowEntries; spacing: 3
                        delegate: Controls.Button {
                            id: overflowEntry
                            required property var modelData
                            width: overflowList.width; height: 32
                            text: modelData.label
                            palette.buttonText: pal.fg; palette.button: pal.dark ? "#38393e" : "#ededf0"
                            onClicked: ui.activateOverflow(modelData, Qt.LeftButton)
                            MouseArea {
                                anchors.fill: parent; acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                                onClicked: mouse => ui.activateOverflow(overflowEntry.modelData, mouse.button)
                                onWheel: wheel => {
                                    if (overflowEntry.modelData.type === "volume") root.setVolume(root.volume + (wheel.angleDelta.y > 0 ? .03 : -.03));
                                    else if (overflowEntry.modelData.type === "keyboard") root.cycleKeyboardLayout(wheel.angleDelta.y > 0 ? -1 : 1);
                                    else wheel.accepted = false;
                                }
                            }
                        }
                    }
                }

                Item {
                    id: volPop
                    z: 10
                    width: 330
                    height: Math.min(volCol.height + 28, ui.height - root.barHeight - 40)
                    x: ui.popupX(width, scale, transformOrigin)
                    y: root.barHeight + 6
                    opacity: ui.pop === "vol" ? 1 : 0
                    visible: opacity > 0
                    scale: root.barPopupScale * (ui.pop === "vol" ? 1 : 0.96)
                    transformOrigin: Item.Top
                    Behavior on opacity { NumberAnimation { duration: 110 } }
                    Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                    LGlass {
                        anchors.fill: parent
                        backdrop: ui.glassSrc
                        shaderUrl: root.glassShaderUrl
                        liquid: root.liquidActive
                        dark: root.effDark

                        cornerR: 26
                        tint: root.glassOpacity
                        thickness: 22
                        strength: 0.7 * root.glassLiquid
                        rim: root.glassRim
                        grain: root.glassGrain
                        blur: root.glassBlur
                        debug: root.glassDebug
                        onShaderError: root.glassState = "failed"
                    }
                    MouseArea { anchors.fill: parent }      // clicks inside don't close the popover
                    Flickable {
                        id: volFlick
                        x: 0; y: 14
                        width: parent.width
                        height: parent.height - 28
                        contentWidth: width
                        contentHeight: volCol.height
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        interactive: contentHeight > height
                        Column {
                            id: volCol
                            x: 14
                            width: volFlick.width - 28
                            spacing: 3

                            Text { x: 4; text: Language.I18n.text("ui.t_a2396c2e9a67") + Math.round(root.volume * 100) + "%"; color: pal.fg2; font.family: pal.fam; font.pixelSize: 12; font.weight: Font.DemiBold; bottomPadding: 3 }
                            Item {
                                width: parent.width; height: 32
                                CCSlider {
                                    t: pal
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width
                                    maximumValue: root.maxVolume
                                    value: root.muted ? 0 : root.volume
                                    leftKind: "speaker"; leftLevel: root.volLevel
                                    rightKind: "speaker"; rightLevel: 3
                                    onMoved: v => root.setVolume(v)
                                }
                                MouseArea { width: 28; height: parent.height; onClicked: root.toggleMute() }     // the left speaker icon mutes
                            }
                            Repeater {
                                model: root.audioOutputs
                                delegate: AudioRow {
                                    required property var modelData
                                    t: pal
                                    readonly property var parts: root.audioSplit(modelData.description || modelData.name)
                                    title: parts[0]
                                    sub: parts[1]
                                    kind: root.audioKind(modelData, true)
                                    selected: root.sink !== null && root.sink !== undefined && root.sink.id === modelData.id
                                    onClicked: root.chooseAudio(modelData)
                                }
                            }
                            Text { visible: root.audioOutputs.length === 0; x: 4; text: Language.I18n.text("ui.t_fcdbdde0caae"); color: pal.fg2; font.family: pal.fam; font.pixelSize: 12; topPadding: 4; bottomPadding: 4 }
                            Item { width: 1; height: 5 }
                            Text { x: 4; text: "Apps"; color: pal.fg2; font.family: pal.fam; font.pixelSize: 12; font.weight: Font.DemiBold; bottomPadding: 2 }
                            Repeater {
                                model: root.appAudioStreams
                                delegate: Item {
                                    required property var modelData
                                    width: volCol.width - 28; height: 54
                                    Text {
                                        x: 4; y: 0; width: parent.width - 8
                                        text: modelData.name + "  ·  " + Math.round(modelData.volume * 100) + "%"
                                        color: pal.fg; elide: Text.ElideRight
                                        font.family: pal.fam; font.pixelSize: 12
                                    }
                                    CCSlider {
                                        t: pal; x: 0; y: 20; width: parent.width
                                        maximumValue: root.maxVolume
                                        value: modelData.volume
                                        leftKind: "speaker"; leftLevel: modelData.volume < 0.34 ? 1 : (modelData.volume < 0.67 ? 2 : 3)
                                        rightKind: "speaker"; rightLevel: 3
                                        onMoved: v => root.setAppVolume(modelData, v)
                                    }
                                }
                            }
                            Text { visible: root.appAudioStreams.length === 0; x: 4; text: Language.I18n.text("ui.t_b5f1856791ae"); color: pal.fg2; font.family: pal.fam; font.pixelSize: 11; topPadding: 2; bottomPadding: 4 }
                            Item { width: 1; height: 5 }
                            Rectangle { width: parent.width; height: 1; color: pal.sep }
                            Item { width: 1; height: 5 }
                            Item {
                                width: parent.width; height: 32
                                Text { x: 4; anchors.verticalCenter: parent.verticalCenter; text: Language.I18n.text("ui.t_36ecb4f86691"); color: pal.fg2; font.family: pal.fam; font.pixelSize: 12; font.weight: Font.DemiBold }
                                Rectangle {
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 30; height: 30; radius: 15
                                    color: root.micMuted ? pal.btnOff : pal.accent
                                    Behavior on color { ColorAnimation { duration: 120 } }
                                    Glyph { anchors.centerIn: parent; width: 16; height: 16; kind: "mic"; flag: root.micMuted; color: root.micMuted ? pal.fg : "white" }
                                    MouseArea { anchors.fill: parent; onClicked: root.toggleMicMute() }
                                }
                            }
                            Item {
                                width: parent.width; height: 32
                                CCSlider {
                                    t: pal
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width
                                    value: root.micMuted ? 0 : root.micVolume
                                    leftKind: "mic"; rightKind: "mic"
                                    onMoved: v => root.setMicVolume(v)
                                }
                            }
                            Repeater {
                                model: root.audioInputs
                                delegate: AudioRow {
                                    required property var modelData
                                    t: pal
                                    readonly property var parts: root.audioSplit(modelData.description || modelData.name)
                                    title: parts[0]
                                    sub: parts[1]
                                    kind: "mic"
                                    selected: root.micSource !== null && root.micSource !== undefined && root.micSource.id === modelData.id
                                    onClicked: root.chooseAudio(modelData)
                                }
                            }
                            Text { visible: root.audioInputs.length === 0; x: 4; text: Language.I18n.text("ui.t_2c90b766675b"); color: pal.fg2; font.family: pal.fam; font.pixelSize: 12; topPadding: 4; bottomPadding: 4 }
                        }
                    }
                }

                // ═════════ keyboard layout popover (right-click the layout label) ═════════
                Item {
                    id: kbPop
                    z: 10
                    width: 250
                    height: kbCol.height + 16
                    x: ui.popupX(width, scale, transformOrigin)
                    y: root.barHeight + 6
                    opacity: ui.pop === "kb" ? 1 : 0
                    visible: opacity > 0
                    scale: root.barPopupScale * (ui.pop === "kb" ? 1 : 0.96)
                    transformOrigin: Item.Top
                    Behavior on opacity { NumberAnimation { duration: 110 } }
                    Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                    LGlass {
                        anchors.fill: parent
                        backdrop: ui.glassSrc
                        shaderUrl: root.glassShaderUrl
                        liquid: root.liquidActive
                        dark: root.effDark

                        cornerR: 22
                        tint: root.glassOpacity
                        thickness: 22
                        strength: 0.7 * root.glassLiquid
                        rim: root.glassRim
                        grain: root.glassGrain
                        blur: root.glassBlur
                        debug: root.glassDebug
                        onShaderError: root.glassState = "failed"
                    }
                    MouseArea { anchors.fill: parent }
                    Column {
                        id: kbCol
                        x: 8; y: 8
                        width: parent.width - 16
                        Repeater {
                            model: root.kbLayouts
                            delegate: Item {
                                id: kr
                                required property var modelData
                                required property int index
                                width: parent.width; height: 40
                                Rectangle { anchors.fill: parent; radius: 12; color: pal.hover; opacity: krMa.containsMouse ? 1 : 0 }
                                Text {
                                    x: 12
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width - 84
                                    elide: Text.ElideRight
                                    text: Language.I18n.legacy(kr.modelData.name)
                                    color: pal.fg
                                    font.family: pal.fam; font.pixelSize: 13
                                    font.weight: kr.index === root.kbIndex ? Font.DemiBold : Font.Normal
                                }
                                Text {
                                    anchors.right: parent.right; anchors.rightMargin: 40
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: kr.modelData.code.toUpperCase()
                                    color: pal.fg2
                                    font.family: pal.fam; font.pixelSize: 11
                                }
                                Glyph {
                                    visible: kr.index === root.kbIndex
                                    anchors.right: parent.right; anchors.rightMargin: 12
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 16; height: 16
                                    kind: "check"; color: pal.fg
                                }
                                MouseArea { id: krMa; anchors.fill: parent; hoverEnabled: true; onClicked: { root.switchKeyboardLayout(kr.index); ui.pop = ""; } }
                            }
                        }
                    }
                }

                // ═════════ notification popups (top right, under the bar) ═════════
                Item {
                    id: toastMask
                    x: toastArea.x; y: toastArea.y
                    width: ui.toastsShown ? toastArea.width : 0
                    height: ui.toastsShown ? toastArea.height : 0
                }
                Item {
                    id: toastArea
                    z: 12
                    width: 364
                    x: ui.width - width - 10
                    // a menu / popover open where the notifications are: they slide down below it, and back up after
                    readonly property real popBottom: {
                        if (ui.pop === "" || ui.pop === "spot") return 0;
                        var items = [overflowPop, servicePop, menuPop, cc, cal, wifiPop, btPop, trayPop, volPop, kbPop], b = 0;
                        for (var i = 0; i < items.length; i++) {
                            var it = items[i];
                            if (!it || !it.visible) continue;
                            if (it.x < x + width && it.x + it.width > x) b = Math.max(b, it.y + it.height);
                        }
                        return b;
                    }
                    y: popBottom > 0 ? popBottom + 12 : root.barHeight + 8
                    Behavior on y { NumberAnimation { duration: 770; easing.type: Easing.OutQuint } }
                    height: toastCol.height
                    visible: ui.toastsShown && root.notificationsEnabled
                    Column {
                        id: toastCol
                        width: parent.width
                        spacing: 10
                        // the rest of the stack glides to its new place instead of jumping
                        move: Transition { NumberAnimation { properties: "y"; duration: 770; easing.type: Easing.OutQuint } }
                        Repeater {
                            model: notifToasts
                            delegate: Item {
                                id: toast
                                required property int nid
                                required property string app
                                required property string summary
                                required property string body
                                required property string icon
                                required property int urgency
                                required property real time
                                required property int timeout
                                property bool shown: false
                                property bool leaving: false
                                readonly property int life: timeout > 0 ? timeout : (urgency === 2 ? 10000 : 6000)
                                // t: 0 = a small pill at the right edge (off to the side), 1 = the full card in place
                                property real t: (shown && !leaving) ? 1 : 0
                                Behavior on t { NumberAnimation { duration: 770; easing.type: toast.leaving ? Easing.OutCubic : Easing.OutQuint } }
                                readonly property real tc: Math.max(0, Math.min(1, t))
                                width: toastCol.width
                                // the slot grows with the card, so the stack below makes room smoothly
                                height: tbody.height * (0.35 + 0.65 * tc) + (toastCol.spacing * (tc - 1))
                                opacity: Math.min(1, tc * 2.2)
                                Component.onCompleted: shown = true
                                function dismiss() { if (leaving) return; leaving = true; goneTimer.restart(); }
                                // Notification Center opened: record this popup's spot and hand over instantly — the card in the
                                // panel starts exactly here and flies into its slot (one object, no duplicate)
                                property real mergeDy: 0
                                Timer { id: handOff; interval: 30; onTriggered: root.notifToastRemove(toast.nid) }
                                Connections {
                                    target: root
                                    function onNotifOpenChanged() {
                                        if (!root.notifOpen || toast.leaving || toast.tc < 0.5) return;
                                        var g = tslab.mapToItem(ui, 0, 0);
                                        // a NEW object, or nothing is notified and the cards never start their flight
                                        var m = {}, old = root.notifMergeFrom;
                                        for (var k in old) m[k] = old[k];
                                        m[toast.nid] = { x: g.x, y: g.y, w: tslab.width };
                                        root.notifMergeFrom = m;
                                        toast.leaving = true;
                                        toast.visible = false;
                                        handOff.restart();
                                    }
                                }
                                Timer { interval: 790; id: goneTimer; onTriggered: root.notifToastRemove(toast.nid) }
                                Timer {
                                    interval: toast.life
                                    running: toast.shown && !toast.leaving && !thov.hovered
                                    onTriggered: toast.dismiss()
                                }
                                HoverHandler { id: thov }

                                LGlass {
                                    id: tslab
                                    // pill → card: narrow and short at first, anchored to the right, sliding in from the right
                                    readonly property real slide: (1 - toast.tc) * 46
                                    width: toast.width * (0.42 + 0.58 * toast.tc)
                                    height: Math.max(36, toast.height)
                                    x: toast.width - width + slide
                                    backdrop: ui.glassSrc
                                    shaderUrl: root.glassShaderUrl
                                    liquid: root.liquidActive
                                    dark: root.effDark

                                    cornerR: Math.min(24 + (1 - toast.tc) * 40, height / 2)
                                    tint: root.glassOpacity
                                    thickness: 22
                                    strength: 0.7 * root.glassLiquid
                                    rim: root.glassRim
                                    grain: root.glassGrain
                                    blur: root.notifBlur
                                    debug: root.glassDebug
                                    onShaderError: root.glassState = "failed"
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    objectName: "notificationActivate_" + toast.nid
                                    // Activation removes this delegate synchronously.
                                    onClicked: root.notifActivate(toast.nid)
                                }
                                // the slab reveals the content (clip), and inside it the content comes into focus. The blur sits on an
                                // inner layer with room to spread (auto padding), so it is soft all round instead of a cut-off smear,
                                // and it eases out gradually as the card settles.
                                Item {
                                    id: tcontent
                                    x: tslab.x; width: tslab.width; height: toast.height
                                    clip: toast.tc < 0.999
                                    opacity: Math.pow(toast.tc, 1.3)
                                Item {
                                    width: toast.width; height: toast.height
                                    x: tslab.width - width
                                    layer.enabled: toast.tc < 0.999
                                    layer.smooth: true
                                    layer.effect: MultiEffect { blurEnabled: true; blurMax: 56; blur: Math.pow(1 - toast.tc, 0.8); autoPaddingEnabled: true }
                                NotifBody {
                                    id: tbody
                                    t: pal
                                    width: toast.width
                                    app: toast.app; summary: toast.summary; body: toast.body; icon: toast.icon
                                    urgency: toast.urgency; stamp: toast.time; nowMs: clock.date.getTime()
                                    showClose: thov.hovered
                                    onCloseClicked: toast.dismiss()
                                }
                                }
                                }
                            }
                        }
                    }
                }

                // ═════════ notification centre (bell) r ═════════
                Item {
                    id: notifPop
                    z: 10
                    width: 380
                    // while clearing it tracks the collapsing list frame by frame (never shorter than the empty state),
                    // so the dust and the shrink are one motion; otherwise it eases to its new size
                    height: 92 + (notifHist.count === 0 ? 70 : (root.notifClearing ? Math.max(70, nfl.height) : nfl.height)) + 14
                    Behavior on height { enabled: !root.notifClearing; NumberAnimation { duration: 560; easing.type: Easing.OutQuint } }
                    x: ui.popupX(width, scale, transformOrigin)
                    y: root.barHeight + 6
                    opacity: ui.pop === "notif" ? 1 : 0
                    visible: opacity > 0
                    scale: root.barPopupScale * (ui.pop === "notif" ? 1 : 0.96)
                    transformOrigin: Item.TopRight
                    // popups merging in: the panel appears at once (its cards are the popups, solid from the first frame) and only
                    // its chrome (glass, header, Do Not Disturb) builds in around them
                    readonly property bool merging: ui.toastsShown
                    property real chrome: ui.pop === "notif" ? 1 : 0
                    Behavior on chrome { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
                    Behavior on opacity { enabled: !notifPop.merging; NumberAnimation { duration: 280; easing.type: Easing.OutCubic } }
                    Behavior on scale { enabled: !notifPop.merging; NumberAnimation { duration: 420; easing.type: Easing.OutQuint } }

                    LGlass {
                        anchors.fill: parent
                        opacity: notifPop.chrome
                        backdrop: ui.glassSrc
                        shaderUrl: root.glassShaderUrl
                        liquid: root.liquidActive
                        dark: root.effDark

                        cornerR: 26
                        tint: root.glassOpacity
                        thickness: 26
                        strength: 0.8 * root.glassLiquid
                        rim: root.glassRim
                        grain: root.glassGrain
                        blur: root.notifBlur
                        debug: root.glassDebug
                        onShaderError: root.glassState = "failed"
                    }
                    MouseArea { anchors.fill: parent }      // clicks inside the panel don't close it

                    Item {
                        x: 18; y: 14; width: parent.width - 36; height: 26
                        opacity: notifPop.chrome
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: Language.I18n.text("ui.t_fa3ea3dda5df")
                            color: pal.fg
                            font.family: pal.fam; font.pixelSize: 17; font.weight: Font.DemiBold
                        }
                        Rectangle {
                            visible: notifHist.count > 0
                            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                            width: clrText.implicitWidth + 20; height: 24; radius: 12
                            color: clrMa.containsMouse ? pal.btnHover : pal.btnOff
                            Text {
                                id: clrText
                                anchors.centerIn: parent
                                text: Language.I18n.text("ui.t_ddceb7adfdb8")
                                color: pal.fg
                                font.family: pal.fam; font.pixelSize: 12; font.weight: Font.Medium
                            }
                            MouseArea { id: clrMa; anchors.fill: parent; hoverEnabled: true; onClicked: root.notifClearAnimated() }
                        }
                    }
                    Item {
                        x: 12; y: 46; width: parent.width - 24; height: 36
                        opacity: notifPop.chrome
                        Rectangle { anchors.fill: parent; radius: 12; color: pal.tile; border.width: 1; border.color: pal.tileBorder }
                        Glyph { x: 12; anchors.verticalCenter: parent.verticalCenter; width: 15; height: 15; kind: "moon"; color: pal.fg }
                        Text {
                            x: 36; anchors.verticalCenter: parent.verticalCenter
                            text: Language.I18n.text("ui.t_d0b47b15de45")
                            color: pal.fg
                            font.family: pal.fam; font.pixelSize: 13
                        }
                        Rectangle {
                            anchors.right: parent.right; anchors.rightMargin: 10; anchors.verticalCenter: parent.verticalCenter
                            width: 38; height: 22; radius: 11
                            color: root.notifDnd ? pal.accent : pal.switchOff
                            Behavior on color { ColorAnimation { duration: 120 } }
                            Rectangle {
                                y: 2; width: 18; height: 18; radius: 9; color: "white"
                                x: root.notifDnd ? 18 : 2
                                Behavior on x { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                            }
                            MouseArea { anchors.fill: parent; onClicked: root.notifDnd = !root.notifDnd }
                        }
                    }
                    Text {
                        // fades in as the list finishes collapsing (no pop at the end of Clear All)
                        opacity: notifHist.count === 0 ? 1 : 0
                        visible: opacity > 0.01
                        Behavior on opacity { NumberAnimation { duration: 360; easing.type: Easing.OutCubic } }
                        x: 0; y: 96; width: parent.width; height: 60
                        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                        text: Language.I18n.text("ui.t_d963c3ae148d")
                        color: pal.fg2
                        font.family: pal.fam; font.pixelSize: 14
                    }
                    Flickable {
                        id: nfl
                        x: 12; y: 92
                        width: parent.width - 24
                        height: Math.min(ncol.height, 440)
                        contentHeight: ncol.height
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        Column {
                            id: ncol
                            width: nfl.width
                            spacing: 8
                            Repeater {
                                model: notifHist
                                delegate: Dissolve {
                                    id: hcd
                                    required property int nid
                                    required property int index
                                    required property string app
                                    required property string summary
                                    required property string body
                                    required property string icon
                                    required property int urgency
                                    required property real time
                                    width: ncol.width
                                    // entrance: grows into the list (cards below glide down), slides in from above, comes into focus
                                    property real inT: 0
                                    property bool snapIn: false
                                    Component.onCompleted: inT = 1
                                    Behavior on inT { enabled: !hcd.snapIn && !root.notifClearing; NumberAnimation { duration: 560; easing.type: Easing.OutQuint } }
                                    // morph from the popup: the card starts at the popup's spot / width and flies into its slot
                                    property real flipX: 0
                                    property real flipY: 0
                                    property real flipS: 1
                                    function flyFromPopup() {
                                        var f = root.notifMergeFrom[hcd.nid];
                                        if (!f || flipAnim.running) return;
                                        // the card's final width is the panel's list width (the list may not be laid out yet)
                                        var cw = notifPop.width - 24;
                                        if (!(cw > 0)) return;
                                        var here = hcd.mapToItem(ui, 0, 0);
                                        hcd.flipX = f.x + f.w - (here.x + cw);      // right edges line up (scale origin is the right edge)
                                        // starts where its popup was, but never above the list's top edge (it would be clipped there)
                                        var listTop = nfl.mapToItem(ui, 0, 0).y;
                                        hcd.flipY = Math.max(f.y, listTop) - here.y;
                                        hcd.flipS = Math.max(0.5, Math.min(1.5, f.w / cw));
                                        flyDelay.interval = 1 + Math.max(0, hcd.index) * 40;
                                        flyDelay.restart();
                                    }
                                    Timer { id: flyDelay; onTriggered: flipAnim.restart() }
                                    ParallelAnimation {
                                        id: flipAnim
                                        NumberAnimation { target: hcd; property: "flipX"; to: 0; duration: 620; easing.type: Easing.OutQuint }
                                        NumberAnimation { target: hcd; property: "flipY"; to: 0; duration: 620; easing.type: Easing.OutQuint }
                                        NumberAnimation { target: hcd; property: "flipS"; to: 1; duration: 620; easing.type: Easing.OutQuint }
                                    }
                                    Connections {
                                        target: root
                                        function onNotifMergeFromChanged() { Qt.callLater(hcd.flyFromPopup); }
                                    }
                                    height: hc.height * inT
                                    cardH: hc.height
                                    opacity: inT
                                    transform: [
                                        Scale { origin.x: hcd.width; origin.y: 0; xScale: hcd.flipS; yScale: hcd.flipS },
                                        Translate { x: hcd.flipX; y: (hcd.inT - 1) * 18 + hcd.flipY }
                                    ]
                                    z: (flipAnim.running || flyDelay.running) ? 10 : 0
                                    // after the dust: the gap closes smoothly, then the entry is removed
                                    onDone: { if (root.notifClearing) return; hcd.inT = 0; delT.restart(); }
                                    Timer { id: delT; interval: 560; onTriggered: root.notifDelete(hcd.nid) }
                                    // during Clear All the slot shrinks while the card turns to dust (one fluid motion)
                                    Timer { id: collapseT; onTriggered: collapseAnim.restart() }
                                    NumberAnimation { id: collapseAnim; target: hcd; property: "inT"; to: 0; duration: 820; easing.type: Easing.InOutCubic }
                                    Connections {
                                        target: root
                                        function onNotifDustAll() {
                                            hcd.dissolve(hcd.index * 55);
                                            collapseT.interval = 120 + hcd.index * 55; collapseT.restart();
                                        }
                                    }
                                Rectangle {
                                    id: hc
                                    readonly property int nid: hcd.nid
                                    readonly property string app: hcd.app
                                    readonly property string summary: hcd.summary
                                    readonly property string body: hcd.body
                                    readonly property string icon: hcd.icon
                                    readonly property int urgency: hcd.urgency
                                    readonly property real time: hcd.time
                                    width: hcd.width
                                    height: hbody.height
                                    radius: 18
                                    color: pal.tile
                                    border.width: 1; border.color: pal.tileBorder
                                    HoverHandler { id: hhov }
                                    MouseArea {
                                        anchors.fill: parent
                                        onClicked: { root.notifActivate(hc.nid); ui.pop = ""; }
                                    }
                                    NotifBody {
                                        id: hbody
                                        t: pal
                                        width: parent.width
                                        app: hc.app; summary: hc.summary; body: hc.body; icon: hc.icon
                                        urgency: hc.urgency; stamp: hc.time; nowMs: clock.date.getTime()
                                        showTime: true
                                        showClose: hhov.hovered
                                        onCloseClicked: hcd.dissolve(1)          // dust away, then removed
                                    }
                                }
                                }
                            }
                        }
                    }
                }

                // ═════════ dropdown menu (Apple / app / File / Edit / …) ═════════
                Item {
                    id: menuPop
                    z: 10
                    width: 260
                    height: menuCol.height + 14
                    x: ui.popupX(width, scale, transformOrigin, true)
                    y: root.barHeight + 3
                    opacity: ui.isMenu ? 1 : 0
                    visible: opacity > 0
                    scale: root.barPopupScale * (ui.isMenu ? 1 : 0.97)
                    transformOrigin: Item.TopLeft
                    Behavior on opacity { NumberAnimation { duration: 90 } }
                    Behavior on scale { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }

                    LGlass {
                        anchors.fill: parent
                        backdrop: ui.glassSrc
                        shaderUrl: root.glassShaderUrl
                        liquid: root.liquidActive
                        dark: root.effDark

                        cornerR: 14
                        tint: root.glassOpacity
                        thickness: 22
                        strength: 0.55 * root.glassLiquid
                        rim: root.glassRim
                        grain: root.glassGrain
                        blur: root.glassBlur
                        debug: root.glassDebug
                        onShaderError: root.glassState = "failed"
                    }
                    Column {
                        id: menuCol
                        x: 6; y: 7
                        width: parent.width - 12
                        Repeater {
                            model: ui.menuModel
                            delegate: Item {
                                id: it
                                required property var modelData
                                readonly property bool isSep: modelData.kind === "sep"
                                readonly property bool armedNow: !isSep && modelData.confirm === true && ui.armed === modelData.label
                                readonly property bool off: !isSep && modelData.disabled === true
                                readonly property bool hot: !isSep && !off && ima.containsMouse
                                width: menuCol.width
                                height: isSep ? 11 : 26

                                Rectangle {
                                    visible: it.isSep
                                    anchors.verticalCenter: parent.verticalCenter
                                    x: 8; width: parent.width - 16; height: 1
                                    color: pal.sep
                                }
                                Rectangle {
                                    visible: it.hot
                                    anchors.fill: parent
                                    radius: 6
                                    color: it.armedNow ? "#FF453A" : root.accent
                                }
                                Text {
                                    visible: !it.isSep && it.modelData.checked === true
                                    x: 11
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "\u2713"
                                    color: it.hot ? "white" : pal.fg
                                    font.family: pal.fam
                                    font.pixelSize: 13
                                }
                                Text {
                                    visible: !it.isSep
                                    x: ui.menuLead ? 28 : 12
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width - x - 12 - (sc.visible ? sc.implicitWidth + 12 : 0)
                                    elide: Text.ElideRight
                                    text: it.isSep ? "" : (it.armedNow ? Language.I18n.text("ui.t_1f8c95036230") : it.modelData.label)
                                    color: it.hot ? "white" : (it.off ? pal.fg2 : pal.fg)
                                    font.family: pal.fam
                                    font.pixelSize: 13
                                }
                                Text {
                                    id: sc
                                    visible: !it.isSep && it.modelData.shortcut !== undefined && it.modelData.shortcut !== ""
                                    anchors.right: parent.right
                                    anchors.rightMargin: 12
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: it.isSep ? "" : (it.modelData.shortcut || "")
                                    color: it.hot ? Qt.rgba(1, 1, 1, 0.8) : pal.fg2
                                    font.family: pal.fam
                                    font.pixelSize: 12
                                }
                                MouseArea {
                                    id: ima
                                    anchors.fill: parent
                                    enabled: !it.isSep && !it.off
                                    hoverEnabled: true
                                    onClicked: {
                                        if (it.modelData.confirm === true && ui.armed !== it.modelData.label) {
                                            ui.armed = it.modelData.label;
                                            return;
                                        }
                                        var run = it.modelData.run;
                                        ui.pop = "";
                                        if (run) run();
                                    }
                                }
                            }
                        }
                    }
                }

                // ═════════ system tray menu (right-click a tray icon) ═════════
                Item {
                    id: trayPop
                    z: 10
                    readonly property bool shown: ui.pop === "tray"
                    readonly property var cur: ui.trayStack.length > 0 ? ui.trayStack[ui.trayStack.length - 1]
                                               : (ui.trayItem ? ui.trayItem.menu : null)
                    readonly property bool hasLead: {
                        var v = trayOpener.children ? trayOpener.children.values : [];
                        for (var i = 0; i < v.length; i++)
                            if (v[i].buttonType !== QsMenuButtonType.None || (v[i].icon && v[i].icon !== "")) return true;
                        return false;
                    }
                    function clean(t) {     // dbusmenu mnemonics: "_File" -> "File", "__" -> "_"
                        return (t || "").replace(/__/g, "\u0001").replace(/_/g, "").replace(/\u0001/g, "_");
                    }
                    width: 260
                    height: Math.min(trayCol.height + 14, root.popRoom - 20)
                    x: ui.popupX(width, scale, transformOrigin, true)
                    y: root.barHeight + 3
                    opacity: shown ? 1 : 0
                    visible: opacity > 0
                    scale: root.barPopupScale * (shown ? 1 : 0.97)
                    transformOrigin: Item.TopLeft
                    Behavior on opacity { NumberAnimation { duration: 90 } }
                    Behavior on scale { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }

                    QsMenuOpener { id: trayOpener; menu: trayPop.cur }

                    LGlass {
                        anchors.fill: parent
                        backdrop: ui.glassSrc
                        shaderUrl: root.glassShaderUrl
                        liquid: root.liquidActive
                        dark: root.effDark

                        cornerR: 14
                        tint: root.glassOpacity
                        thickness: 22
                        strength: 0.55 * root.glassLiquid
                        rim: root.glassRim
                        grain: root.glassGrain
                        blur: root.glassBlur
                        debug: root.glassDebug
                        onShaderError: root.glassState = "failed"
                    }

                    Flickable {
                        id: trayFlick
                        x: 6; y: 7
                        width: parent.width - 12
                        height: parent.height - 14
                        contentWidth: width
                        contentHeight: trayCol.height
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        interactive: contentHeight > height
                        Connections { target: trayPop; function onCurChanged() { trayFlick.contentY = 0; } }

                        Column {
                            id: trayCol
                            width: trayFlick.width

                            // submenu header: click to go back one level
                            Item {
                                id: trayBack
                                visible: ui.trayStack.length > 0
                                width: trayCol.width
                                height: visible ? 26 : 0
                                Rectangle {
                                    anchors.fill: parent
                                    radius: 6
                                    color: backMa.containsMouse ? root.accent : "transparent"
                                }
                                Text {
                                    x: 12
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width - 24
                                    elide: Text.ElideRight
                                    text: "\u2039  " + (ui.trayStack.length > 0 ? trayPop.clean(ui.trayStack[ui.trayStack.length - 1].text) : "")
                                    color: backMa.containsMouse ? "white" : pal.fg
                                    font.family: pal.fam; font.pixelSize: 13; font.weight: Font.DemiBold
                                }
                                MouseArea {
                                    id: backMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onClicked: ui.trayStack = ui.trayStack.slice(0, ui.trayStack.length - 1)
                                }
                            }
                            Item {
                                visible: trayBack.visible
                                width: trayCol.width; height: visible ? 11 : 0
                                Rectangle { anchors.verticalCenter: parent.verticalCenter; x: 8; width: parent.width - 16; height: 1; color: pal.sep }
                            }

                            Repeater {
                                model: trayOpener.children
                                delegate: Item {
                                    id: te
                                    required property var modelData
                                    readonly property bool isSep: modelData.isSeparator
                                    readonly property bool live: !isSep && modelData.enabled
                                    readonly property bool hot: live && tma.containsMouse
                                    width: trayCol.width
                                    height: isSep ? 11 : 26

                                    Rectangle {
                                        visible: te.isSep
                                        anchors.verticalCenter: parent.verticalCenter
                                        x: 8; width: parent.width - 16; height: 1
                                        color: pal.sep
                                    }
                                    Rectangle {
                                        visible: te.hot
                                        anchors.fill: parent
                                        radius: 6
                                        color: root.accent
                                    }
                                    // check mark / radio dot / app-provided icon
                                    Text {
                                        visible: !te.isSep && te.modelData.buttonType !== QsMenuButtonType.None && te.modelData.checkState === Qt.Checked
                                        x: 10
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: te.modelData.buttonType === QsMenuButtonType.RadioButton ? "\u25CF" : "\u2713"
                                        color: te.hot ? "white" : (te.live ? pal.fg : pal.fg2)
                                        font.family: pal.fam
                                        font.pixelSize: te.modelData.buttonType === QsMenuButtonType.RadioButton ? 8 : 13
                                    }
                                    Image {
                                        visible: !te.isSep && te.modelData.buttonType === QsMenuButtonType.None && te.modelData.icon !== ""
                                        x: 10
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 16; height: 16
                                        source: te.modelData.icon
                                        sourceSize: Qt.size(32, 32)
                                        fillMode: Image.PreserveAspectFit
                                        opacity: te.live ? 1 : 0.4
                                    }
                                    Text {
                                        visible: !te.isSep
                                        x: trayPop.hasLead ? 32 : 12
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: parent.width - x - 12 - (te.modelData.hasChildren ? 14 : 0)
                                        elide: Text.ElideRight
                                        text: te.isSep ? "" : trayPop.clean(te.modelData.text)
                                        color: te.hot ? "white" : (te.live ? pal.fg : pal.fg2)
                                        font.family: pal.fam
                                        font.pixelSize: 13
                                    }
                                    Text {
                                        visible: !te.isSep && te.modelData.hasChildren
                                        anchors.right: parent.right
                                        anchors.rightMargin: 10
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: "\u203A"
                                        color: te.hot ? "white" : pal.fg2
                                        font.family: pal.fam; font.pixelSize: 15
                                    }
                                    MouseArea {
                                        id: tma
                                        anchors.fill: parent
                                        enabled: te.live
                                        hoverEnabled: true
                                        onClicked: {
                                            if (te.modelData.hasChildren) {
                                                ui.trayStack = ui.trayStack.concat([te.modelData]);
                                            } else {
                                                te.modelData.triggered();
                                                ui.pop = "";
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                Item {
                    id: servicePop
                    property string contentName: "stats"
                    z: 10
                    width: Math.min(390, (ui.width - 16) / root.barPopupScale)
                    height: Math.min(serviceContent.implicitHeight + 24, (Math.min(win.modelData.height, ui.height) - root.barHeight - 24) / root.barPopupScale)
                    x: ui.popupX(width, scale, transformOrigin)
                    y: root.barHeight + 6
                    scale: root.barPopupScale
                    transformOrigin: Item.TopLeft
                    readonly property bool opened: ["stats", "wifijoin", "focus", "awake", "night", "btpair", "record", "battery", "airplay"].indexOf(ui.pop) >= 0
                    opacity: opened ? 1 : 0
                    visible: opacity > 0
                    Behavior on opacity { NumberAnimation { duration: 120 } }
                    LGlass {
                        anchors.fill: parent
                        backdrop: ui.glassSrc
                        shaderUrl: root.glassShaderUrl
                        liquid: root.liquidActive
                        dark: root.effDark

                        cornerR: 22
                        tint: root.glassOpacity
                        strength: .7 * root.glassLiquid
                        rim: root.glassRim; grain: root.glassGrain; blur: root.glassBlur
                        onShaderError: root.glassState = "failed"
                    }
                    MouseArea { anchors.fill: parent }
                    Flickable {
                        x: 12; y: 12; width: parent.width - 24; height: parent.height - 24
                        contentHeight: serviceContent.implicitHeight; clip: true
                        Loader {
                            id: serviceContent
                            width: parent.width
                            active: servicePop.visible
                            sourceComponent: servicePop.contentName === "airplay" ? mirroringComponent : servicePop.contentName === "battery" ? batteryComponent : servicePop.contentName === "record" ? recordingComponent : servicePop.contentName === "btpair" ? pairComponent : servicePop.contentName === "wifijoin" ? joinComponent : servicePop.contentName === "focus" || servicePop.contentName === "awake" ? durationComponent : servicePop.contentName === "night" ? nightComponent : statsComponent
                            Component { id: mirroringComponent; ScreenMirroringMenu { controller: root.mirroring; t: pal; onBackRequested: ui.pop = "cc" } }
                            Component { id: batteryComponent; BatteryMenu { battery: root.battery; power: root.power; t: pal; onSettingsRequested: { ui.pop = ""; root.openSettings("battery"); } } }
                            Component { id: durationComponent; DurationMenu { controller: root.timedModes; kind: servicePop.contentName; t: pal; onBackRequested: ui.pop = "cc" } }
                            Component { id: nightComponent; NightShiftMenu { controller: root.nightShift; t: pal; onBackRequested: ui.pop = "cc"; onTemperaturePicked: value => root.nightTemp = value; onEnabledPicked: value => root.nightDesired = value } }
                            Component { id: recordingComponent; RecordingMenu { controller: root.recorder; t: pal; onBackRequested: ui.pop = "cc" } }
                            Component { id: pairComponent; BluetoothPairDialog { controller: root.bluetooth; t: pal } }
                            Component { id: joinComponent; WifiJoinDialog { controller: root.wifi; t: pal } }
                            Component {
                                id: statsComponent
                                SystemStatsMenu {
                                    controller: root.stats; t: pal; accent: pal.accent
                                    onBackRequested: ui.pop = "cc"
                                    onSettingsRequested: { ui.pop = ""; root.openSettings("menubar"); }
                                }
                            }
                        }
                    }
                }

                // ═════════ Bluetooth devices ═════════
                Item {
                    id: btPop
                    objectName: "bluetoothPage"
                    z: 10
                    width: parent === cc ? cc.width : 340
                    height: Math.min(btMenu.height + 24, (Math.min(win.modelData.height, ui.height) - root.barHeight - 24) / root.barPopupScale)
                    x: parent === cc ? 0 : ui.popupX(width, scale, transformOrigin)
                    y: parent === cc ? 0 : root.barHeight + 6
                    parent: ui.anchorType === "controlCenter" && ui.pop === "bt" ? cc : ui
                    opacity: ui.pop === "bt" ? 1 : 0
                    visible: opacity > 0
                    scale: parent === cc ? 1 : root.barPopupScale * (ui.pop === "bt" ? 1 : 0.96)
                    transformOrigin: Item.Top
                    Behavior on opacity { NumberAnimation { duration: 110 } }
                    Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                    LGlass {
                        anchors.fill: parent
                        backdrop: ui.glassSrc
                        shaderUrl: root.glassShaderUrl
                        liquid: root.liquidActive
                        dark: root.effDark

                        cornerR: 22
                        tint: root.glassOpacity
                        thickness: 24
                        strength: 0.7 * root.glassLiquid
                        rim: root.glassRim
                        grain: root.glassGrain
                        blur: root.glassBlur
                        debug: root.glassDebug
                        onShaderError: root.glassState = "failed"
                    }
                    MouseArea { anchors.fill: parent }
                    Flickable {
                        objectName: "bluetoothPageScroll"
                        x: 12; y: 12; width: parent.width - 24; height: parent.height - 24
                        contentHeight: btMenu.height; clip: true
                        BluetoothMenu {
                            id: btMenu
                            width: parent.width
                            t: pal; controller: root.bluetooth
                            maxListHeight: Math.max(52, Math.min(280, (win.modelData.height - root.barHeight - 240) / root.barPopupScale))
                            onBackRequested: ui.openPop("cc", ui.width, ui.anchorOverflow, "controlCenter")
                            onSettingsRequested: { ui.pop = ""; root.openSettings("bluetooth"); }
                        }
                    }
                }

                // ═════════ Wi-Fi networks ═════════
                Item {
                    id: wifiPop
                    objectName: "wifiPage"
                    z: 10
                    parent: ui.anchorType === "controlCenter" && ui.pop === "wifi" ? cc : ui
                    width: parent === cc ? cc.width : 320
                    height: Math.min(wifiCol.height + 24, (Math.min(win.modelData.height, ui.height) - root.barHeight - 24) / root.barPopupScale)
                    x: parent === cc ? 0 : ui.popupX(width, scale, transformOrigin)
                    y: parent === cc ? 0 : root.barHeight + 6
                    opacity: ui.pop === "wifi" ? 1 : 0
                    visible: opacity > 0
                    scale: parent === cc ? 1 : root.barPopupScale * (ui.pop === "wifi" ? 1 : 0.96)
                    transformOrigin: Item.Top
                    Behavior on opacity { NumberAnimation { duration: 110 } }
                    Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

                    LGlass {
                        anchors.fill: parent
                        backdrop: ui.glassSrc
                        shaderUrl: root.glassShaderUrl
                        liquid: root.liquidActive
                        dark: root.effDark

                        cornerR: 22
                        tint: root.glassOpacity
                        thickness: 24
                        strength: 0.7 * root.glassLiquid
                        rim: root.glassRim
                        grain: root.glassGrain
                        blur: root.glassBlur
                        debug: root.glassDebug
                        onShaderError: root.glassState = "failed"
                    }
                    MouseArea { anchors.fill: parent }          // swallow clicks on empty glass so the popover doesn't close

                    Flickable {
                        objectName: "wifiPageScroll"
                        x: 12; y: 12
                        width: parent.width - 24; height: parent.height - 24
                        contentWidth: width; contentHeight: wifiCol.height
                        clip: true; boundsBehavior: Flickable.StopAtBounds
                    Column {
                        id: wifiCol
                        width: parent.width
                        spacing: 6

                        // header: title + on/off switch
                        Item {
                            width: parent.width; height: 32
                            Rectangle {
                                visible: ui.anchorType === "controlCenter"
                                width: 26; height: 28; radius: 8; anchors.verticalCenter: parent.verticalCenter
                                color: wifiBack.containsMouse ? pal.hover : "transparent"
                                Glyph { anchors.centerIn: parent; width: 13; height: 13; kind: "chevL"; color: pal.fg }
                                MouseArea { id: wifiBack; objectName: "wifiBackButton"; anchors.fill: parent; hoverEnabled: true; onClicked: ui.openPop("cc", ui.width, ui.anchorOverflow, "controlCenter") }
                            }
                            Text {
                                x: ui.anchorType === "controlCenter" ? 32 : 6; anchors.verticalCenter: parent.verticalCenter
                                text: "Wi-Fi"
                                color: pal.fg
                                font.family: pal.fam; font.pixelSize: 15; font.weight: Font.DemiBold
                            }
                            PSwitch {
                                t: pal
                                anchors.right: parent.right; anchors.rightMargin: 4
                                anchors.verticalCenter: parent.verticalCenter
                                checked: root.wifiOn
                                onToggled: { root.toggleWifi(); wifiAfter.restart(); }
                            }
                        }
                        Rectangle { width: parent.width; height: 1; color: pal.sep }
                        Text { visible: root.otherConnections.length>0; width:parent.width; leftPadding:6; text:Language.I18n.text("ui.t_0fb0d3323a26"); color:pal.fg2; font.family:pal.fam; font.pixelSize:11; font.weight:Font.DemiBold }
                        Column {
                            width: parent.width
                            Repeater {
                                model: root.otherConnections.slice(0,5)
                                delegate: Item {
                                    required property var modelData
                                    width: parent.width; height: 30
                                    Rectangle { anchors.fill:parent; radius:8; color:connMa.containsMouse?pal.hover:"transparent" }
                                    Glyph { x:8; anchors.verticalCenter:parent.verticalCenter; width:14; height:14; kind:modelData.type==="vpn"?"lock":"wifi"; color:pal.fg }
                                    Text { x:30; anchors.verticalCenter:parent.verticalCenter; width:parent.width-42; elide:Text.ElideRight; text:modelData.name+(modelData.active?Language.I18n.text("ui.t_1d93760af6d9"):""); color:pal.fg; font.family:pal.fam; font.pixelSize:12 }
                                    MouseArea { id:connMa; anchors.fill:parent; hoverEnabled:true; onClicked:root.toggleConnection(modelData) }
                                }
                            }
                        }

                        Text {
                            visible: !root.wifiOn
                            width: parent.width; height: 56
                            horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                            text: Language.I18n.text("ui.t_2c4c56b42eac")
                            color: pal.fg2
                            font.family: pal.fam; font.pixelSize: 13
                        }
                        Text {
                            visible: root.wifiOn && root.wifiNets.length === 0
                            width: parent.width; height: 56
                            horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                            text: root.wifiScanning ? Language.I18n.text("ui.t_c31723ab3302") : Language.I18n.text("ui.t_679de4a6058d")
                            color: pal.fg2
                            font.family: pal.fam; font.pixelSize: 13
                        }
                        Text {
                            visible: root.wifiOn && root.wifiNets.length > 0
                            leftPadding: 6
                            text: Language.I18n.text("ui.t_ab2c47c3c77f")
                            color: pal.fg2
                            font.family: pal.fam; font.pixelSize: 11; font.weight: Font.DemiBold
                        }

                        // the list
                        Flickable {
                            id: wifiFlick
                            objectName: "wifiListScroll"
                            visible: root.wifiOn && root.wifiNets.length > 0
                            width: parent.width
                            height: Math.min(wifiList.height, 300)
                            contentWidth: width
                            contentHeight: wifiList.height
                            clip: true
                            boundsBehavior: Flickable.StopAtBounds

                            Column {
                                id: wifiList
                                width: wifiFlick.width
                                Repeater {
                                    model: root.wifiNets
                                    delegate: Column {
                                        id: nr
                                        required property var modelData
                                        readonly property bool busy: root.wifiBusy === modelData.ssid
                                        readonly property bool prompting: ui.wifiPrompt === modelData.ssid
                                        width: wifiList.width

                                        Item {
                                            width: parent.width; height: 38
                                            Rectangle {
                                                anchors.fill: parent
                                                radius: 8
                                                color: root.accent
                                                visible: wma.containsMouse
                                            }
                                            Glyph {
                                                visible: nr.modelData.inUse
                                                x: 9; anchors.verticalCenter: parent.verticalCenter
                                                width: 14; height: 14
                                                kind: "check"
                                                color: wma.containsMouse ? "white" : pal.fg
                                            }
                                            Text {
                                                x: 30
                                                anchors.verticalCenter: parent.verticalCenter
                                                width: parent.width - 30 - 96
                                                elide: Text.ElideRight
                                                text: nr.modelData.ssid + " · " + nr.modelData.interface
                                                color: wma.containsMouse ? "white" : pal.fg
                                                font.family: pal.fam; font.pixelSize: 13
                                                font.weight: nr.modelData.inUse ? Font.DemiBold : Font.Normal
                                            }
                                            Text {
                                                visible: nr.busy
                                                anchors.right: parent.right; anchors.rightMargin: 12
                                                anchors.verticalCenter: parent.verticalCenter
                                                text: Language.I18n.text("ui.t_72021eb70e91")
                                                color: pal.fg2
                                                font.family: pal.fam; font.pixelSize: 12
                                            }
                                            Text {
                                                visible: !nr.busy && nr.modelData.inUse && wma.containsMouse
                                                anchors.right: parent.right; anchors.rightMargin: 12
                                                anchors.verticalCenter: parent.verticalCenter
                                                text: Language.I18n.text("ui.t_acfc5be785a9")
                                                color: "white"
                                                font.family: pal.fam; font.pixelSize: 12
                                            }
                                            Row {
                                                visible: !nr.busy && !(nr.modelData.inUse && wma.containsMouse)
                                                anchors.right: parent.right; anchors.rightMargin: 10
                                                anchors.verticalCenter: parent.verticalCenter
                                                spacing: 7
                                                Glyph {
                                                    visible: nr.modelData.secure
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    width: 13; height: 13
                                                    kind: "lock"
                                                    color: wma.containsMouse ? "white" : pal.fg2
                                                }
                                                Glyph {
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    width: 16; height: 16
                                                    kind: "wifi"; level: root.sigLevel(nr.modelData.signal)
                                                    color: wma.containsMouse ? "white" : pal.fg
                                                }
                                            }
                                            MouseArea {
                                                id: wma
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                enabled: !nr.busy
                                                onClicked: ui.wifiPick(nr.modelData)
                                            }
                                        }

                                        // password field (secured network that has no saved profile)
                                        Item {
                                            visible: nr.prompting
                                            width: parent.width; height: 42
                                            Rectangle {
                                                x: 30; y: 3
                                                width: parent.width - 30 - 4; height: 32; radius: 10
                                                color: pal.btnOff
                                            }
                                            Text {
                                                x: 42; y: 3; height: 32
                                                verticalAlignment: Text.AlignVCenter
                                                visible: pw.text === ""
                                                text: Language.I18n.text("ui.t_e7cf3ef4f17c")
                                                color: pal.fg3
                                                font.family: pal.fam; font.pixelSize: 13
                                            }
                                            TextInput {
                                                id: pw
                                                x: 42; y: 3
                                                width: parent.width - 42 - 62; height: 32
                                                verticalAlignment: TextInput.AlignVCenter
                                                clip: true
                                                echoMode: TextInput.Password
                                                color: pal.fg
                                                selectionColor: root.accent
                                                selectedTextColor: "white"
                                                font.family: pal.fam; font.pixelSize: 13
                                                onVisibleChanged: if (visible) { text = ""; forceActiveFocus(); }
                                                Keys.onPressed: event => {
                                                    if (event.key === Qt.Key_Escape) { ui.wifiPrompt = ""; event.accepted = true; }
                                                    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                                        ui.wifiSubmit(nr.modelData.ssid, text); event.accepted = true;
                                                    }
                                                }
                                            }
                                            Text {
                                                anchors.right: parent.right; anchors.rightMargin: 16
                                                y: 3; height: 32
                                                verticalAlignment: Text.AlignVCenter
                                                text: Language.I18n.text("ui.t_fd30fe681b4b")
                                                color: pw.text.length > 0 ? root.accent : pal.fg3
                                                font.family: pal.fam; font.pixelSize: 13; font.weight: Font.DemiBold
                                                MouseArea {
                                                    anchors.fill: parent; anchors.margins: -6
                                                    onClicked: ui.wifiSubmit(nr.modelData.ssid, pw.text)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        Text {
                            visible: root.wifiError !== ""
                            width: parent.width
                            leftPadding: 6; rightPadding: 6
                            wrapMode: Text.WordWrap
                            text: root.wifiError
                            color: "#FF6961"
                            font.family: pal.fam; font.pixelSize: 12
                        }

                        Rectangle { width: parent.width; height: 1; color: pal.sep }
                        Item {
                            width: parent.width; height: 30
                            Rectangle {
                                anchors.fill: parent; radius: 8
                                color: root.accent
                                visible: wsa.containsMouse
                            }
                            Text {
                                x: 10; anchors.verticalCenter: parent.verticalCenter
                                text: Language.I18n.text("ui.t_a3aaea148928")
                                color: wsa.containsMouse ? "white" : pal.fg
                                font.family: pal.fam; font.pixelSize: 13
                            }
                            MouseArea {
                                id: wsa
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: { ui.pop = ""; root.openSettings("wifi"); }
                            }
                        }
                    }
                    }
                }

                // ═════════ calendar ═════════
                Item {
                    id: cal
                    z: 10
                    width: 310
                    height: calCol.height + 28
                    x: ui.popupX(width, scale, transformOrigin)
                    y: root.barHeight + 6
                    opacity: ui.pop === "cal" ? 1 : 0
                    visible: opacity > 0
                    scale: root.barPopupScale * (ui.pop === "cal" ? 1 : 0.96)
                    transformOrigin: Item.TopRight
                    Behavior on opacity { NumberAnimation { duration: 110 } }
                    Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

                    LGlass {
                        anchors.fill: parent
                        backdrop: ui.glassSrc
                        shaderUrl: root.glassShaderUrl
                        liquid: root.liquidActive
                        dark: root.effDark

                        cornerR: 24
                        tint: root.glassOpacity
                        thickness: 26
                        strength: 0.8 * root.glassLiquid
                        rim: root.glassRim
                        grain: root.glassGrain
                        blur: root.glassBlur
                        debug: root.glassDebug
                        onShaderError: root.glassState = "failed"
                    }
                    Column {
                        id: calCol
                        x: 16; y: 14
                        width: parent.width - 32
                        spacing: 8

                        Text {
                            text: Language.I18n.formatDateTime(clock.date, "dddd")
                            color: pal.fg2
                            font.family: pal.fam; font.pixelSize: 12; font.weight: Font.DemiBold
                        }
                        Text {
                            text: Language.I18n.formatDateTime(clock.date, "d MMMM yyyy")
                            color: pal.fg
                            font.family: pal.fam; font.pixelSize: 22; font.weight: Font.DemiBold
                        }
                        Item { width: 1; height: 2 }
                        Item {
                            width: parent.width; height: 26
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: Language.I18n.formatLocale.monthName(ui.calMonth, Locale.LongFormat) + " " + ui.calYear
                                color: pal.fg
                                font.family: pal.fam; font.pixelSize: 14; font.weight: Font.DemiBold
                            }
                            Row {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 2
                                Repeater {
                                    model: [{ k: "chevL", d: -1 }, { k: "chevR", d: 1 }]
                                    delegate: Rectangle {
                                        required property var modelData
                                        width: 26; height: 26; radius: 13
                                        color: cna.containsMouse ? pal.hover : "transparent"
                                        Glyph { anchors.centerIn: parent; width: 13; height: 13; kind: parent.modelData.k; color: pal.fg }
                                        MouseArea { id: cna; anchors.fill: parent; hoverEnabled: true; onClicked: ui.shiftMonth(parent.modelData.d) }
                                    }
                                }
                            }
                        }
                        Row {
                            Repeater {
                                model: 7
                                delegate: Text {
                                    required property int index
                                    width: calCol.width / 7
                                    horizontalAlignment: Text.AlignHCenter
                                    text: Language.I18n.formatLocale.dayName((index + (root.weekStartsMonday ? 1 : 0)) % 7, Locale.ShortFormat).substring(0, 2)
                                    color: pal.fg2
                                    font.family: pal.fam; font.pixelSize: 11; font.weight: Font.DemiBold
                                }
                            }
                        }
                        Grid {
                            columns: 7
                            Repeater {
                                model: ui.calData
                                delegate: Item {
                                    required property var modelData
                                    width: calCol.width / 7
                                    height: 32
                                    Rectangle {
                                        anchors.centerIn: parent
                                        width: 28; height: 28; radius: 14
                                        color: parent.modelData.today ? root.accent : "transparent"
                                    }
                                    Text {
                                        anchors.centerIn: parent
                                        text: parent.modelData.n
                                        color: parent.modelData.today ? "white" : (parent.modelData.cur ? pal.fg : pal.fg3)
                                        font.family: pal.fam
                                        font.pixelSize: 13
                                        font.weight: parent.modelData.today ? Font.DemiBold : Font.Normal
                                    }
                                }
                            }
                        }
                    }
                }

                // ═════════ Control Center ═════════
                // No panel behind it: every tile and every button is its own piece of Liquid Glass.
                Item {
                    id: cc
                    objectName: "controlCenterPanel"
                    z: 10
                    width: 340
                    height: Math.max(ccCol.height, wifiPop.parent === cc ? wifiPop.height : 0, btPop.parent === cc ? btPop.height : 0)
                    x: ui.popupX(width, scale, transformOrigin)
                    y: root.barHeight + 6
                    // opening (ColorOS 17): the panel springs out from the Control Center button, overshoots a little and
                    // settles, while the controls stretch up into place one row after another. Closing is quick and flat.
                    readonly property bool opening: ui.pop === "cc" || (ui.anchorType === "controlCenter" && (ui.pop === "wifi" || ui.pop === "bt"))
                    property int openSeq: 0
                    property real openT: opening ? 1 : 0
                    Behavior on openT {
                        NumberAnimation {
                            duration: cc.opening ? 520 : 150
                            easing.type: cc.opening ? Easing.OutBack : Easing.OutCubic
                            easing.overshoot: 1.5
                        }
                    }
                    opacity: Math.max(0, Math.min(1, openT * 2.2))
                    visible: opacity > 0
                    scale: root.barPopupScale
                    transformOrigin: Item.TopRight
                    // the panel itself never moves above the bar (the menu bar is transparent, so anything that did would
                    // show straight through it). The motion lives in the controls: they slide up into place inside it.
                    onOpeningChanged: if (opening) openSeq++
                    onVisibleChanged: if (visible) { root.refreshWifi(); root.refreshBt(); root.refreshBrightness(); }

                    MappedRect { id: ccMapping; sourceItem: cc; targetItem: ui; padding: 64 }
                    ShaderEffectSource {
                        id: ccSrc
                        sourceItem: ui.glassSrc
                        hideSource: true
                        live: true
                        visible: false
                        sourceRect: ccMapping.rect
                    }
                    MultiEffect {
                        id: ccBlurFx
                        source: ccSrc
                        width: ccSrc.sourceRect.width; height: ccSrc.sourceRect.height
                        blurEnabled: ccg.blur * ccg.blurMul > 0
                        blurMax: 64
                        blur: Math.min(1.0, (ccg.blur * ccg.blurMul) * 1.4 / 64.0)
                        autoPaddingEnabled: false
                        visible: false
                    }
                    // real Gaussian pre-blur of the backdrop (Qt MultiEffect): the glass shader refracts THIS texture,
                    // so there are no sampled copies of the background any more
                    ShaderEffectSource {
                        id: ccBlur
                        sourceItem: ccBlurFx
                        live: true
                        visible: false
                    }
                    MultiEffect {
                        id: ccBlur2Fx
                        source: ccBlur
                        width: ccSrc.sourceRect.width; height: ccSrc.sourceRect.height
                        blurEnabled: (ccg.blur * ccg.blurMul) * 1.4 / 64.0 > 1.0
                        blurMax: 64
                        blur: Math.max(0.0, Math.min(1.0, (ccg.blur * ccg.blurMul) * 1.4 / 64.0 - 1.0))
                        autoPaddingEnabled: false
                        visible: false
                    }
                    // second Gaussian pass: only active when the slider goes past a single pass's 64 px limit
                    ShaderEffectSource {
                        id: ccBlur2
                        sourceItem: (ccg.blur * ccg.blurMul) * 1.4 / 64.0 > 1.0 ? ccBlur2Fx : null
                        live: true
                        visible: false
                    }
                    GlassCtx {
                        id: ccg
                        src: (blur * blurMul) * 1.4 / 64.0 > 1.0 ? ccBlur2 : ccBlur
                        srcRect: ccSrc.sourceRect
                        frame: ui
                        liquid: root.liquidActive
                        shaderUrl: root.glassShaderUrl
                        dark: root.effDark
                        // macOS style: the panel is the glass, so each control only keeps a faint shape on top of it
                        tint: root.ccStyle === "macos" ? root.glassOpacity * 0.30 : root.glassOpacity
                        strength: root.ccStyle === "macos" ? root.glassLiquid * 0.30 : root.glassLiquid
                        rim: root.ccStyle === "macos" ? root.glassRim * 0.45 : root.glassRim
                        grain: root.glassGrain
                        blur: root.glassBlur
                        debug: root.glassDebug
                        onFailed: root.glassState = "failed"
                    }

                    // ── the controls themselves (instantiated by the grid below) ──
                    function ccComp(id) {
                        switch (id) {
                        case "wifi": return cWifi;
                        case "bluetooth": return cBt;
                        case "airplane": return cAirplane;
                        case "focus": return cFocus;
                        case "nightshift": return cNight;
                        case "keepawake": return cAwake;
                        case "darkmode": return cDark;
                        case "nowplaying": return cNowPlaying;
                        case "display": return cDisplay;
                        case "sound": return cSound;
                        case "record": return cRecord;
                        case "mirroring": return cMirroring;
                        case "airdrop": return cAirDrop;
                        case "gaming": return cGaming;
                        }
                        return null;
                    }
                    Component {
                        id: cWifi
                        CCTile {
                            t: pal; gx: ccg
                            CCBtn {
                                t: pal; gx: ccg
                                x: 12; anchors.verticalCenter: parent.verticalCenter
                                kind: "wifi"; level: root.wifiOn ? (root.wifiLevel || 3) : 3
                                on: root.wifiOn
                                onClicked: root.toggleWifi()
                            }
                            MouseArea {
                                objectName: "controlCenterWifiPage"
                                x: 56; width: parent.width - 56; height: parent.height
                                onClicked: ui.openPop("wifi", ui.width, ui.anchorOverflow, ui.anchorType || "controlCenter")
                            }
                            Glyph {
                                x: parent.width - 22; anchors.verticalCenter: parent.verticalCenter
                                width: 12; height: 12
                                kind: "chevR"; color: pal.fg2
                            }
                            Column {
                                x: 62; anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - 62 - 24
                                spacing: 1
                                Text { text: "Wi-Fi"; color: pal.fg; font.family: pal.fam; font.pixelSize: 13; font.weight: Font.DemiBold }
                                MorphText {
                                    animateWidth: false; duration: 420
                                    width: parent.width; elide: Text.ElideRight
                                    text: !root.wifiOn ? Language.I18n.text("ui.t_ca7981b46ecf") : (root.wifiSsid !== "" ? root.wifiSsid : Language.I18n.text("ui.t_87d82c046732"))
                                    color: pal.fg2; font.family: pal.fam; font.pixelSize: 12
                                }
                            }
                        }
                    }
                    Component {
                        id: cBt
                        CCTile {
                            t: pal; gx: ccg
                            CCBtn {
                                t: pal; gx: ccg
                                x: 12; anchors.verticalCenter: parent.verticalCenter
                                kind: "bluetooth"; on: root.btOn
                                enabled: root.bluetooth.available && !root.bluetooth.busy
                                opacity: enabled ? 1 : 0.45
                                onClicked: root.toggleBt()
                            }
                            MouseArea {
                                objectName: "controlCenterBluetoothPage"
                                x: 56; width: parent.width - 56; height: parent.height
                                onClicked: ui.openPop("bt", ui.width, ui.anchorOverflow, ui.anchorType || "controlCenter")
                            }
                            Glyph {
                                x: parent.width - 22; anchors.verticalCenter: parent.verticalCenter
                                width: 12; height: 12
                                kind: "chevR"; color: pal.fg2
                            }
                            Column {
                                x: 62; anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - 86; spacing: 1
                                Text { text: Language.I18n.text("ui.t_8bb29098b369"); color: pal.fg; font.family: pal.fam; font.pixelSize: 13; font.weight: Font.DemiBold }
                                MorphText {
                                    animateWidth: false; duration: 420
                                    width: parent.width; elide: Text.ElideRight
                                    text: root.bluetooth.busyAction === "power" ? Language.I18n.text("ui.t_dfe40efe921f")
                                          : (!root.bluetooth.available ? Language.I18n.text("common.unavailable")
                                          : (!root.btOn ? Language.I18n.text("ui.t_ca7981b46ecf") : (root.btConnected > 0 ? root.btConnected + Language.I18n.text("ui.t_db6a973be8ac") : Language.I18n.text("ui.t_87d82c046732"))))
                                    color: pal.fg2; font.family: pal.fam; font.pixelSize: 12
                                }
                            }
                        }
                    }
                    Component {
                        id: cAirplane
                        CCTile {
                            t: pal; gx: ccg
                            CCBtn {
                                t: pal; gx: ccg; anchors.centerIn: parent
                                kind: "airplane"; on: root.airplane
                                onClicked: root.toggleAirplane()
                            }
                        }
                    }
                    Component {
                        id: cFocus
                        CCTile {
                            t: pal; gx: ccg
                            CCBtn {
                                t: pal; gx: ccg
                                x: 12; anchors.verticalCenter: parent.verticalCenter
                                kind: "moon"; on: root.dnd
                                onClicked: root.toggleDnd()
                            }
                            Column {
                                x: 62; anchors.verticalCenter: parent.verticalCenter
                                spacing: 1
                                Text { text: Language.I18n.text("ui.t_9d3cab2b5efe"); color: pal.fg; font.family: pal.fam; font.pixelSize: 13; font.weight: Font.DemiBold }
                                MorphText { animateWidth: false; duration: 420; text: root.timedModes.label("focus"); color: pal.fg2; font.family: pal.fam; font.pixelSize: 12 }
                            }
                            MouseArea { x: 58; width: parent.width - 58; height: parent.height; onClicked: ui.openPop("focus", ui.width - 180, ui.anchorOverflow, ui.anchorType || "controlCenter") }
                        }
                    }
                    Component {
                        id: cGaming
                        CCTile {
                            t: pal; gx: ccg
                            CCBtn {
                                t: pal; gx: ccg
                                x: 12; anchors.verticalCenter: parent.verticalCenter
                                kind: "gamepad"; on: root.gaming; onTint: "#30D158"
                                onClicked: root.gamingMode = !root.gaming
                            }
                            Column {
                                x: 62; anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - 62 - 10
                                spacing: 1
                                Text { width: parent.width; elide: Text.ElideRight; text: Language.I18n.text("ui.t_1311d7944778"); color: pal.fg; font.family: pal.fam; font.pixelSize: 13; font.weight: Font.DemiBold }
                                MorphText { animateWidth: false; duration: 420; width: parent.width; elide: Text.ElideRight; text: root.gamingAutoActive && !root.gamingMode ? Language.I18n.text("ui.t_e22aed4b4c91") : (root.gaming ? Language.I18n.text("ui.t_130011756125") : (root.gamingAuto ? Language.I18n.text("ui.t_0286249762f7") : Language.I18n.text("ui.t_ca7981b46ecf")))
                                       color: root.gaming ? "#30D158" : pal.fg2; font.family: pal.fam; font.pixelSize: 12 }
                            }
                        }
                    }
                    Component {
                        id: cRecord
                        CCTile {
                            t: pal; gx: ccg
                            CCBtn {
                                t: pal; gx: ccg
                                x: 12; anchors.verticalCenter: parent.verticalCenter
                                kind: root.recording ? "stoprec" : "record"; on: root.recording; onTint: "#FF453A"
                                onClicked: root.toggleRecording()
                            }
                            Column {
                                x: 62; anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - 62 - 10
                                spacing: 1
                                MorphText { animateWidth: false; duration: 420; width: parent.width; elide: Text.ElideRight; text: root.recording ? Language.I18n.text("ui.t_cae7d57bc067") : Language.I18n.text("ui.t_bfdd510698ef"); color: pal.fg; font.family: pal.fam; font.pixelSize: 13; font.weight: Font.DemiBold }
                                MorphText { animateWidth: false; duration: 420; width: parent.width; elide: Text.ElideRight; text: root.recording ? root.recTime() : Language.I18n.text("ui.t_6e56137e21d3"); color: root.recording ? "#FF453A" : pal.fg2; font.family: pal.fam; font.pixelSize: 12 }
                            }
                        }
                    }
                    Component {
                        id: cMirroring
                        CCTile {
                            t: pal; gx: ccg
                            CCBtn {
                                t: pal; gx: ccg
                                x: 12; anchors.verticalCenter: parent.verticalCenter
                                kind: "mirroring"; on: root.mirroring.sending || root.mirroring.receiving
                                onClicked: ui.openPop("airplay", ui.width, ui.anchorOverflow, ui.anchorType || "controlCenter")
                            }
                            Column {
                                x: 62; anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - 84; spacing: 1
                                Text { width: parent.width; text: Language.I18n.text("ui.t_a72c5d7ed939"); elide: Text.ElideRight; color: pal.fg; font.family: pal.fam; font.pixelSize: 12; font.weight: Font.DemiBold }
                                MorphText { width: parent.width; animateWidth: false; elide: Text.ElideRight; text: root.mirroring.label; color: pal.fg2; font.family: pal.fam; font.pixelSize: 12 }
                            }
                            MouseArea { x: 58; width: parent.width - 58; height: parent.height; onClicked: ui.openPop("airplay", ui.width, ui.anchorOverflow, ui.anchorType || "controlCenter") }
                        }
                    }
                    Component {
                        id: cAirDrop
                        CCTile {
                            t: pal; gx: ccg
                            CCBtn {
                                t: pal; gx: ccg; x: 12; anchors.verticalCenter: parent.verticalCenter
                                kind: "airdrop"; on: airDropControl.active
                                onClicked: root.controlRequested("airdrop")
                            }
                            Column {
                                x: 62; anchors.verticalCenter: parent.verticalCenter; width: parent.width - 84; spacing: 1
                                Text { width: parent.width; text: Language.I18n.text("ui.t_9ccc01839580"); elide: Text.ElideRight; color: pal.fg; font.family: pal.fam; font.pixelSize: 13; font.weight: Font.DemiBold }
                                MorphText { width: parent.width; animateWidth: false; elide: Text.ElideRight; text: airDropControl.label; color: pal.fg2; font.family: pal.fam; font.pixelSize: 12 }
                            }
                            MouseArea { x: 58; width: parent.width - 58; height: parent.height; onClicked: root.controlRequested("airdrop") }
                        }
                    }
                    Component {
                        id: cNight
                        CCTile {
                            t: pal; gx: ccg
                            CCBtn {
                                objectName: "nightShiftToggle"
                                t: pal; gx: ccg; x: Math.max(6, (parent.width - width) / 2 - 8); anchors.verticalCenter: parent.verticalCenter
                                kind: "nightshift"; on: root.nightOn; onTint: "#FF9F0A"
                                onClicked: root.toggleNightShift()
                            }
                            Controls.AbstractButton {
                                objectName: "nightShiftSettings"
                                anchors.right: parent.right; width: 24; height: parent.height
                                Accessible.name: Language.I18n.text("ui.t_ec026cdcadf6")
                                contentItem: Item {
                                    Glyph { anchors.centerIn: parent; width: 12; height: 12; kind: "chevR"; color: pal.fg2 }
                                }
                                onClicked: ui.openPop("night", ui.width - 180, ui.anchorOverflow, ui.anchorType || "controlCenter")
                            }
                        }
                    }
                    Component {
                        id: cAwake
                        CCTile {
                            t: pal; gx: ccg
                            CCBtn {
                                t: pal; gx: ccg; anchors.centerIn: parent
                                kind: "coffee"; on: root.keepAwake
                                onClicked: ui.openPop("awake", ui.width - 180, ui.anchorOverflow, ui.anchorType || "controlCenter")
                            }
                        }
                    }
                    Component {
                        id: cDark
                        CCTile {
                            t: pal; gx: ccg
                            CCBtn {
                                t: pal; gx: ccg; anchors.centerIn: parent
                                objectName: "ccTheme"; kind: "contrast"; on: root.darkMode
                                onClicked: root.darkMode = !root.darkMode
                            }
                        }
                    }
                    Component {
                        id: cNowPlaying
                        CCTile {
                            id: np
                            t: pal; gx: ccg
                            readonly property var pl: root.player
                            Rectangle {
                                id: art
                                x: 12; y: 12
                                width: 52; height: 52; radius: 10
                                color: pal.btnOff
                                Glyph { visible: artImg.status !== Image.Ready; anchors.centerIn: parent; width: 22; height: 22; kind: "note"; color: pal.fg2 }
                                // `clip: true` only clips to a plain rectangle, so the cover is masked with a rounded shape instead
                                Item {
                                    id: artMask
                                    anchors.fill: parent
                                    visible: false
                                    layer.enabled: true
                                    layer.smooth: true
                                    Rectangle { anchors.fill: parent; radius: art.radius; color: "black" }
                                }
                                Image {
                                    id: artImg
                                    anchors.fill: parent
                                    source: np.pl && np.pl.trackArtUrl ? np.pl.trackArtUrl : ""
                                    fillMode: Image.PreserveAspectCrop
                                    asynchronous: true
                                    smooth: true
                                    layer.enabled: true
                                    layer.smooth: true
                                    layer.effect: MultiEffect {
                                        maskEnabled: true
                                        maskSource: artMask
                                        maskThresholdMin: 0.5
                                        maskSpreadAtMin: 1.0
                                    }
                                }
                                // hairline edge like the macOS cover art
                                Rectangle {
                                    anchors.fill: parent
                                    radius: art.radius
                                    color: "transparent"
                                    border.width: 1
                                    border.color: pal.dark ? Qt.rgba(1, 1, 1, 0.12) : Qt.rgba(0, 0, 0, 0.10)
                                }
                            }
                            Column {
                                x: 12; y: 66
                                width: parent.width - 24
                                spacing: 1
                                Text {
                                    width: parent.width; elide: Text.ElideRight
                                    text: np.pl && np.pl.trackTitle ? np.pl.trackTitle : Language.I18n.text("ui.t_8b2ae991573c")
                                    color: np.pl ? pal.fg : pal.fg2
                                    font.family: pal.fam; font.pixelSize: 13; font.weight: Font.DemiBold
                                }
                                Text {
                                    visible: np.pl !== null && np.pl !== undefined
                                    width: parent.width; elide: Text.ElideRight
                                    text: np.pl && np.pl.trackArtist ? np.pl.trackArtist : ""
                                    color: pal.fg2; font.family: pal.fam; font.pixelSize: 12
                                }
                            }
                            Row {
                                anchors.horizontalCenter: parent.horizontalCenter
                                y: parent.height - 38
                                spacing: 2
                                opacity: np.pl ? 1 : 0.4
                                Repeater {
                                    model: ["prev", "play", "next"]
                                    delegate: Item {
                                        id: pbtn
                                        required property string modelData
                                        width: 32; height: 30
                                        Glyph {
                                            anchors.centerIn: parent
                                            width: 26; height: 26
                                            kind: pbtn.modelData === "play" ? (np.pl && np.pl.isPlaying ? "pause" : "play") : pbtn.modelData
                                            color: pal.fg
                                            scale: pma.pressed ? 0.88 : 1
                                            Behavior on scale { NumberAnimation { duration: 230; easing.type: Easing.OutBack; easing.overshoot: 3.2 } }
                                        }
                                        MouseArea {
                                            id: pma
                                            anchors.fill: parent
                                            enabled: np.pl !== null && np.pl !== undefined
                                            onClicked: {
                                                if (pbtn.modelData === "prev") np.pl.previous();
                                                else if (pbtn.modelData === "next") np.pl.next();
                                                else np.pl.togglePlaying();
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Component {
                        id: cDisplay
                        CCTile {
                            t: pal; gx: ccg
                            radius: 26
                            Text {
                                x: 14; y: 8
                                text: Language.I18n.text("ui.t_34e108c0896d")
                                color: pal.fg; font.family: pal.fam; font.pixelSize: 12; font.weight: Font.DemiBold
                            }
                            CCSlider {
                                t: pal
                                x: 12; y: 28
                                width: parent.width - 24
                                value: root.brightness
                                leftKind: "sun"; leftLevel: 1
                                rightKind: "sun"; rightLevel: 3
                                onMoved: v => root.setBrightness(v)
                            }
                        }
                    }
                    Component {
                        id: cSound
                        CCTile {
                            t: pal; gx: ccg
                            radius: 26
                            Text {
                                x: 14; y: 8
                                width: parent.width - 42; elide: Text.ElideRight
                                text: Language.I18n.text("ui.t_03e9c0d3ca73") + Math.round(root.volume * 100) + "%" + (root.sink ? " · " + (root.sink.description || root.sink.name) : "")
                                color: pal.fg; font.family: pal.fam; font.pixelSize: 12; font.weight: Font.DemiBold
                            }
                            Glyph {
                                x: parent.width - 26; y: 10
                                width: 12; height: 12
                                kind: "chevR"; color: pal.fg2
                            }
                            MouseArea {
                                x: 8; y: 0; width: parent.width - 16; height: 28
                                onClicked: ui.openPop("vol", ui.width, ui.anchorOverflow, ui.anchorType || "controlCenter")
                            }
                            CCSlider {
                                t: pal
                                x: 12; y: 28
                                width: parent.width - 24 - 36
                                maximumValue: root.maxVolume
                                value: root.muted ? 0 : root.volume
                                leftKind: "speaker"; leftLevel: 1
                                rightKind: "speaker"; rightLevel: 3
                                onMoved: v => root.setVolume(v)
                            }
                            CCBtn {
                                t: pal; gx: ccg
                                d: 28
                                x: parent.width - 12 - 28; y: 28
                                kind: "speaker"; level: root.muted ? 0 : 3
                                on: root.muted
                                onClicked: root.toggleMute()
                            }
                        }
                    }

                    // macOS Control Center: one frosted slab behind everything (the tiles sit on it, instead of each
                    // control being its own piece of glass)
                    Loader {
                        active: root.ccStyle === "macos"
                        x: -12; y: -12
                        width: cc.width + 24; height: ccCol.height + 24
                        sourceComponent: Item {
                            GGlass { anchors.fill: parent; gx: ccg; cornerR: 24; thickness: 26; strengthMul: 1.0; shadowAmt: 0.6 }
                        }
                    }

                    Column {
                        id: ccCol
                        visible: ui.pop === "cc"
                        x: 0; y: 0
                        width: parent.width
                        spacing: 10

                        // ── privacy: which apps use the microphone / camera / screen (only while something is active) ──
                        Item {
                            id: ccPriv
                            visible: root.privacyAny
                            width: parent.width
                            height: visible ? root.privacyRows.length * 46 + 14 : 0
                            CCTile { anchors.fill: parent; t: pal; gx: ccg; radius: 22 }
                            Column {
                                x: 8; y: 7
                                width: parent.width - 16
                                Repeater {
                                    model: root.privacyRows
                                    delegate: Item {
                                        id: pr
                                        required property var modelData
                                        width: parent.width; height: 46
                                        Rectangle {
                                            x: 4
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: 30; height: 30; radius: 15
                                            color: pr.modelData.c
                                            Glyph { anchors.centerIn: parent; width: 15; height: 15; kind: pr.modelData.glyph; color: "white" }
                                        }
                                        Column {
                                            x: 44
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: parent.width - 44 - (pr.modelData.k === "rec" ? 70 : 6)
                                            spacing: 1
                                            Text { width: parent.width; elide: Text.ElideRight; text: pr.modelData.title; color: pal.fg; font.family: pal.fam; font.pixelSize: 13; font.weight: Font.DemiBold }
                                            Text { width: parent.width; elide: Text.ElideRight; text: pr.modelData.sub; color: pal.fg2; font.family: pal.fam; font.pixelSize: 11 }
                                        }
                                        Rectangle {
                                            visible: pr.modelData.k === "rec"
                                            anchors.right: parent.right; anchors.rightMargin: 4
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: 54; height: 24; radius: 12
                                            color: "#FF453A"
                                            Text { anchors.centerIn: parent; text: Language.I18n.text("ui.t_cae7d57bc067"); color: "white"; font.family: pal.fam; font.pixelSize: 12; font.weight: Font.DemiBold }
                                            MouseArea { anchors.fill: parent; onClicked: root.toggleRecording() }
                                        }
                                    }
                                }
                            }
                        }

                        // ── the control grid ──
                        Item {
                            id: ccGrid
                            width: parent.width
                            height: Math.max(66, root.ccPlan.rows * 76 - 10)
                            readonly property real cw: (width - 30) / 4
                            readonly property real chh: 66

                            Text {
                                visible: root.ccPlan.items.length === 0
                                anchors.centerIn: parent
                                text: Language.I18n.text("ui.t_0b90b14512e9")
                                color: pal.fg2; font.family: pal.fam; font.pixelSize: 12
                            }

                            Repeater {
                                model: root.ccCatalog
                                delegate: Item {
                                    id: ct
                                    required property var modelData
                                    readonly property var slot: {
                                        var it = root.ccPlan.items;
                                        for (var i = 0; i < it.length; i++) if (it[i].id === modelData.id) return it[i];
                                        return null;
                                    }
                                    property real dx: 0
                                    property real dy: 0
                                    property bool dragging: false

                                    visible: slot !== null
                                    x: (slot ? slot.col * (ccGrid.cw + 10) : 0) + dx
                                    y: (slot ? slot.row * (ccGrid.chh + 10) : 0) + dy
                                    width: slot ? slot.w * ccGrid.cw + (slot.w - 1) * 10 : 0
                                    height: slot ? slot.h * ccGrid.chh + (slot.h - 1) * 10 : 0
                                    z: dragging ? 100 : 0
                                    // stretch-and-settle, a touch later for each row / column (ColorOS 17)
                                    property real ap: 1
                                    Connections {
                                        target: cc
                                        function onOpenSeqChanged() { ct.ap = 0; tileIn.restart(); }
                                    }
                                    SequentialAnimation {
                                        id: tileIn
                                        PauseAnimation { duration: ct.slot ? Math.min(220, ct.slot.row * 55 + ct.slot.col * 18) : 0 }
                                        NumberAnimation { target: ct; property: "ap"; from: 0; to: 1; duration: 460; easing.type: Easing.OutBack; easing.overshoot: 1.8 }
                                    }
                                    transform: Translate { y: (1 - ct.ap) * 16 }
                                    opacity: Math.max(0, Math.min(1, ct.ap * 1.6))
                                    scale: dragging ? 1.04 : 1
                                    Behavior on x { enabled: !ct.dragging; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                                    Behavior on y { enabled: !ct.dragging; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                                    Behavior on scale { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }

                                    Loader {
                                        anchors.fill: parent
                                        active: ct.slot !== null
                                        sourceComponent: cc.ccComp(ct.modelData.id)
                                    }

                                    // edit mode: this layer sits above the control, so clicks drag it instead of using it
                                    MouseArea {
                                        id: dragArea
                                        anchors.fill: parent
                                        z: 50
                                        enabled: ui.ccEdit
                                        visible: ui.ccEdit      // a hidden area can't leave the grab cursor behind
                                        preventStealing: true
                                        cursorShape: !ui.ccEdit ? Qt.ArrowCursor : (ct.dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor)
                                        property point startP: Qt.point(0, 0)
                                        onPressed: mouse => {
                                            var q = mapToItem(ccGrid, mouse.x, mouse.y);
                                            startP = Qt.point(q.x, q.y);
                                            ct.dragging = true;
                                        }
                                        onPositionChanged: mouse => {
                                            if (!pressed) return;
                                            var q = mapToItem(ccGrid, mouse.x, mouse.y);
                                            ct.dx = q.x - startP.x;
                                            ct.dy = q.y - startP.y;
                                        }
                                        onReleased: mouse => {
                                            var q = mapToItem(ccGrid, mouse.x, mouse.y);
                                            ct.dragging = false;
                                            ct.dx = 0; ct.dy = 0;
                                            root.ccDrop(ct.modelData.id, q.x, q.y, ccGrid.cw, ccGrid.chh, ccGrid.height);
                                        }
                                        onCanceled: { ct.dragging = false; ct.dx = 0; ct.dy = 0; }
                                    }

                                    // remove badge
                                    Rectangle {
                                        visible: ui.ccEdit
                                        z: 60
                                        x: -5; y: -5
                                        width: 22; height: 22; radius: 11
                                        color: pal.dark ? "#636366" : "#8E8E93"
                                        border.width: 1.5
                                        border.color: pal.dark ? Qt.rgba(1, 1, 1, 0.35) : "white"
                                        Rectangle { anchors.centerIn: parent; width: 10; height: 2; radius: 1; color: "white" }
                                        MouseArea {
                                            anchors.fill: parent; anchors.margins: -3
                                            onClicked: root.ccRemove(ct.modelData.id)
                                        }
                                    }
                                }
                            }
                        }

                        // ── edit mode: controls that are not on the grid yet ──
                        Column {
                            visible: ui.ccEdit && ccAddRep.count > 0
                            width: parent.width
                            spacing: 8
                            Text {
                                leftPadding: 4
                                text: Language.I18n.text("ui.t_2c7f4ce64766")
                                color: pal.fg2
                                font.family: pal.fam; font.pixelSize: 12; font.weight: Font.DemiBold
                            }
                            Flow {
                                width: parent.width
                                spacing: 8
                                Repeater {
                                    id: ccAddRep
                                    model: root.ccCatalog.filter(function (d) { return root.ccControls.indexOf(d.id) < 0; })
                                    delegate: CCTile {
                                        id: chip
                                        required property var modelData
                                        t: pal; gx: ccg
                                        radius: 17
                                        width: chipRow.implicitWidth + 24; height: 34
                                        Row {
                                            id: chipRow
                                            anchors.centerIn: parent
                                            spacing: 7
                                            Rectangle {
                                                width: 18; height: 18; radius: 9
                                                color: "#30D158"
                                                anchors.verticalCenter: parent.verticalCenter
                                                Text { anchors.centerIn: parent; text: "+"; color: "white"; font.pixelSize: 14; font.weight: Font.Bold }
                                            }
                                            Glyph {
                                                width: 16; height: 16
                                                anchors.verticalCenter: parent.verticalCenter
                                                kind: chip.modelData.glyph; color: pal.fg
                                            }
                                            Text {
                                                anchors.verticalCenter: parent.verticalCenter
                                                text: chip.modelData.label
                                                color: pal.fg; font.family: pal.fam; font.pixelSize: 12
                                            }
                                        }
                                        MouseArea { anchors.fill: parent; onClicked: root.ccAdd(chip.modelData.id) }
                                    }
                                }
                            }
                        }

                        // ── edit controls / done ──
                        Item {
                            id: ccEditRow
                            width: parent.width; height: 28
                            // same stretch-and-settle as the control tiles, arriving after the last row
                            property real ap: 1
                            Connections {
                                target: cc
                                function onOpenSeqChanged() { ccEditRow.ap = 0; editIn.restart(); }
                            }
                            SequentialAnimation {
                                id: editIn
                                PauseAnimation { duration: Math.min(220, root.ccPlan.rows * 55 + 40) }
                                NumberAnimation { target: ccEditRow; property: "ap"; from: 0; to: 1; duration: 460; easing.type: Easing.OutBack; easing.overshoot: 1.8 }
                            }
                            transform: Translate { y: (1 - ccEditRow.ap) * 16 }
                            opacity: Math.max(0, Math.min(1, ccEditRow.ap * 1.6))
                            Row {
                                anchors.centerIn: parent
                                spacing: 8
                                CCPill {
                                    visible: ui.ccEdit
                                    t: pal; gx: ccg
                                    text: Language.I18n.text("ui.t_daee7606b339")
                                    onClicked: root.ccControls = root.ccDefault.slice()
                                }
                                CCPill {
                                    t: pal; gx: ccg
                                    text: ui.ccEdit ? Language.I18n.text("common.done") : Language.I18n.text("ui.t_4615ef639d9d")
                                    strong: ui.ccEdit
                                    onClicked: ui.ccEdit = !ui.ccEdit
                                }
                            }
                        }
                    }
                }
            }
        }

        // ═════════ Window switcher (ALT + TAB) lives in its OWN layer (namespace "macswitch") ═════════
        PanelWindow {
            id: swWin
            property var glassSurfaces: []
            BackgroundEffect.blurRegion: GlassRegion { host: swWin }
            screen: perScreen.modelData
            visible: (root.swOpen && ui.toastScreen) || swPanel.opacity > 0
            onVisibleChanged: root.popCount += (visible ? 1 : -1)     // keeps the window-geometry poller running while it is open
            anchors { left: true; right: true; top: true; bottom: true }
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore

            WlrLayershell.namespace: "macswitch"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: (root.swOpen && ui.toastScreen) ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

            Item {
                id: swRoot
                anchors.fill: parent
                focus: true

                // releasing ALT switches to the selected app; TAB / SHIFT+TAB / arrows cycle; ESC cancels
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Tab || event.key === Qt.Key_Right) { root.swNext(1); event.accepted = true; }
                    else if (event.key === Qt.Key_Backtab || event.key === Qt.Key_Left) { root.swNext(-1); event.accepted = true; }
                    else if (event.key === Qt.Key_Escape) { root.swCancel(); event.accepted = true; }
                    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.swCommit(); event.accepted = true; }
                }
                Keys.onReleased: event => {
                    if (event.key === Qt.Key_Alt && !event.isAutoRepeat) { root.swCommit(); event.accepted = true; }
                }

                Loader {
                    id: swBackdrop
                    active: root.liquidActive
                    sourceComponent: backdropComp
                    onLoaded: { item.hostShown = Qt.binding(function () { return swWin.visible; });
                                item.region = Qt.binding(function () { return Qt.rect(swPanel.x - 96, swPanel.y - 96, swPanel.width + 192, swPanel.height + 192); }); }
                }
                MouseArea { anchors.fill: parent; onPressed: root.swCancel() }      // click outside cancels

                Item {
                    id: swPanel
                    z: 10
                    readonly property int n: root.swApps.length
                    readonly property real cw: Math.min(92, (swRoot.width - 160) / Math.max(n, 1))
                    readonly property real ico: Math.round(cw * 0.7)
                    readonly property real pad: 14
                    readonly property real cellH: Math.round(cw * 0.8)
                    readonly property real padY: 9
                    width: n * cw + 2 * pad
                    height: padY + cellH + 25
                    x: Math.round((swRoot.width - width) / 2)
                    y: Math.round(swRoot.height * 0.42 - height / 2)
                    // opens with motion + blur: grows from 92 % while coming into focus; closes quicker
                    readonly property bool shown: root.swOpen && ui.toastScreen
                    opacity: shown ? 1 : 0
                    visible: opacity > 0
                    scale: shown ? 1 : 0.92
                    transformOrigin: Item.Center
                    Behavior on opacity { NumberAnimation { duration: swPanel.shown ? 220 : 160; easing.type: Easing.OutCubic } }
                    Behavior on scale { NumberAnimation { duration: swPanel.shown ? 420 : 200; easing.type: Easing.OutQuint } }
                    property real soft: shown ? 0 : 1
                    Behavior on soft { NumberAnimation { duration: swPanel.shown ? 300 : 160; easing.type: Easing.OutCubic } }
                    layer.enabled: soft > 0.01
                    layer.effect: MultiEffect { blurEnabled: true; blurMax: 32; blur: swPanel.soft * 0.8; autoPaddingEnabled: true }

                    readonly property string style: root.switcherStyle
                    LGlass {
                        anchors.fill: parent
                        visible: swPanel.style !== "opaque"
                        backdrop: swBackdrop.item
                        shaderUrl: root.glassShaderUrl
                        liquid: root.liquidActive
                        dark: root.effDark

                        cornerR: 26
                        // frosted: the same glass with no refraction, a heavier blur and more tint
                        tint: swPanel.style === "frosted" ? Math.max(0.5, root.glassOpacity) : root.glassOpacity
                        thickness: swPanel.style === "frosted" ? 6 : 20
                        strength: swPanel.style === "frosted" ? 0.0 : 0.75 * root.glassLiquid
                        rim: swPanel.style === "frosted" ? 0.15 : root.glassRim
                        grain: root.glassGrain
                        blur: swPanel.style === "frosted" ? 30 : root.switcherBlur
                        debug: root.glassDebug
                        onShaderError: root.glassState = "failed"
                    }
                    Rectangle {
                        anchors.fill: parent
                        visible: swPanel.style === "opaque"
                        radius: 26
                        color: root.effDark ? "#232325" : "#F2F2F5"
                        border.width: 1; border.color: root.effDark ? Qt.rgba(1, 1, 1, 0.12) : Qt.rgba(0, 0, 0, 0.10)
                        layer.enabled: true
                        layer.effect: MultiEffect { shadowEnabled: true; shadowBlur: 1.0; shadowOpacity: 0.35; shadowVerticalOffset: 8 }
                    }

                    // selection highlight (slides between apps)
                    Rectangle {
                        visible: swPanel.n > 0
                        x: swPanel.pad + root.swIndex * swPanel.cw
                        y: swPanel.padY
                        width: swPanel.cw; height: swPanel.cellH
                        radius: 17
                        color: root.darkMode ? Qt.rgba(1, 1, 1, 0.20) : Qt.rgba(0, 0, 0, 0.11)
                        border.width: 1
                        border.color: root.darkMode ? Qt.rgba(1, 1, 1, 0.12) : Qt.rgba(0, 0, 0, 0.06)
                        Behavior on x { NumberAnimation { duration: 320; easing.type: Easing.OutQuint } }
                    }
                    Repeater {
                        model: root.swApps
                        delegate: Item {
                            id: swCell
                            required property int index
                            required property var modelData
                            x: swPanel.pad + index * swPanel.cw
                            y: swPanel.padY
                            width: swPanel.cw; height: swPanel.cellH
                            Image {
                                anchors.centerIn: parent
                                width: swPanel.ico; height: swPanel.ico
                                // the selected app's icon lifts a little
                                scale: root.swIndex === swCell.index ? 1.06 : 0.96
                                Behavior on scale { NumberAnimation { duration: 320; easing.type: Easing.OutQuint } }
                                source: root.swIcon(swCell.modelData)
                                sourceSize.width: 128; sourceSize.height: 128
                                fillMode: Image.PreserveAspectFit
                                smooth: true; mipmap: true
                                asynchronous: true
                            }
                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                onPositionChanged: root.swIndex = swCell.index      // only on real mouse movement, so TAB keeps control
                                onClicked: { root.swIndex = swCell.index; root.swCommit(); }
                            }
                        }
                    }
                    // name of the selected app, under its icon
                    // the name blur-morphs into the next app's while it glides under the new icon
                    // (a fixed-width box centred on the new icon: it starts moving the instant the selection changes, so the
                    //  name glides and morphs at the same time — its position never waits on the morphing text's width)
                    TextMetrics { id: swNameM; font.family: pal.fam; font.pixelSize: 13; font.weight: Font.Medium; text: swName.text }
                    Item {
                        id: swNameBox
                        visible: swPanel.n > 0
                        width: 260; height: swName.implicitHeight
                        readonly property real cx: swPanel.pad + root.swIndex * swPanel.cw + swPanel.cw / 2
                        readonly property real tw: Math.min(swNameM.advanceWidth, swPanel.width - 20)
                        // keep the whole name inside the panel
                        readonly property real cxc: Math.max(10 + tw / 2, Math.min(swPanel.width - 10 - tw / 2, cx))
                        x: cxc - width / 2
                        y: swPanel.padY + swPanel.cellH + 3
                        Behavior on x { NumberAnimation { duration: 320; easing.type: Easing.OutQuint } }
                        MorphText {
                            id: swName
                            width: parent.width
                            text: root.swApps.length > root.swIndex ? root.swApps[root.swIndex].name : ""
                            color: swPanel.style === "opaque" ? (root.effDark ? "white" : "#1D1D1F") : pal.fg
                            font.family: pal.fam; font.pixelSize: 13; font.weight: Font.Medium
                            horizontalAlignment: Text.AlignHCenter
                            animateWidth: false
                            duration: 320
                        }
                    }
                }
            }
        }

        // ═════════ Wallpaper picker (CTRL + ALT + W) lives in its OWN layer (namespace "macwall") ═════════
        PanelWindow {
            id: wpWin
            property var glassSurfaces: []
            BackgroundEffect.blurRegion: GlassRegion { host: wpWin }
            screen: perScreen.modelData
            visible: (root.wpOpen && ui.toastScreen) || wpPanel.opacity > 0
            onVisibleChanged: root.popCount += (visible ? 1 : -1)     // keeps the window-geometry poller running while it is open
            anchors { left: true; right: true; top: true; bottom: true }
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore

            WlrLayershell.namespace: "macwall"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: (root.wpOpen && ui.toastScreen) ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

            Item {
                id: wpRoot
                anchors.fill: parent
                focus: true
                Keys.onEscapePressed: event => { if (root.wpQuery !== "") root.wpQuery = ""; else root.wpOpen = false; event.accepted = true; }
                Connections {
                    target: root
                    function onWpOpenChanged() { if (root.wpOpen) { root.wpQuery = ""; wpGrid.currentIndex = 0; wpGrid.forceActiveFocus(); } }
                    function onWpQueryChanged() {
                        if (wpSearch.text !== root.wpQuery) wpSearch.text = root.wpQuery;
                        wpGrid.currentIndex = 0;
                        wpGrid.positionViewAtBeginning();
                    }
                }

                Loader {
                    id: wpBackdrop
                    active: root.liquidActive
                    sourceComponent: backdropComp
                    onLoaded: { item.hostShown = Qt.binding(function () { return wpWin.visible; });
                                item.region = Qt.binding(function () { return Qt.rect(wpPanel.x - 96, wpPanel.y - 96, wpPanel.width + 192, wpPanel.height + 192); }); }
                }
                MouseArea { anchors.fill: parent; onPressed: root.wpOpen = false }      // click outside closes

                Item {
                    id: wpPanel
                    z: 10
                    width: Math.min(980, wpRoot.width - 120)
                    height: Math.min(640, wpRoot.height - 160)
                    x: Math.round((wpRoot.width - width) / 2)
                    y: Math.round((wpRoot.height - height) / 2)
                    opacity: (root.wpOpen && ui.toastScreen) ? 1 : 0
                    visible: opacity > 0
                    scale: (root.wpOpen && ui.toastScreen) ? 1 : 0.96
                    transformOrigin: Item.Center
                    Behavior on opacity { NumberAnimation { duration: 120 } }
                    Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

                    LGlass {
                        anchors.fill: parent
                        backdrop: wpBackdrop.item
                        shaderUrl: root.glassShaderUrl
                        liquid: root.liquidActive
                        dark: root.effDark

                        cornerR: 28
                        tint: root.glassOpacity
                        thickness: 22
                        strength: 0.75 * root.glassLiquid
                        rim: root.glassRim
                        grain: root.glassGrain
                        blur: root.wpBlur
                        debug: root.glassDebug
                        onShaderError: root.glassState = "failed"
                    }

                    // ── header: title, folder path, Choose… ──
                    Item {
                        id: wpHead
                        x: 22; y: 14
                        width: parent.width - 44; height: 34
                        Text {
                            id: wpTitle
                            anchors.verticalCenter: parent.verticalCenter
                            text: Language.I18n.text("ui.t_006547c4fdf5")
                            color: pal.fg
                            font.family: pal.fam; font.pixelSize: 15; font.weight: Font.DemiBold
                        }
                        Rectangle {
                            id: wpChoose
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            width: 84; height: 30; radius: 10
                            color: wpChooseMa.containsMouse ? pal.btnHover : pal.btnOff
                            Text { anchors.centerIn: parent; text: Language.I18n.text("ui.t_7ca41615c19b"); color: pal.fg; font.family: pal.fam; font.pixelSize: 12; font.weight: Font.Medium }
                            MouseArea { id: wpChooseMa; anchors.fill: parent; hoverEnabled: true; onClicked: root.wpPickFolder() }
                        }
                        Rectangle {
                            anchors.left: wpTitle.right; anchors.leftMargin: 18
                            anchors.right: wpChoose.left; anchors.rightMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            height: 30; radius: 10
                            color: pal.tile
                            border.width: 1
                            border.color: dirInput.activeFocus ? pal.accent : pal.tileBorder
                            TextInput {
                                id: dirInput
                                anchors.fill: parent
                                anchors.leftMargin: 10; anchors.rightMargin: 10
                                verticalAlignment: TextInput.AlignVCenter
                                clip: true
                                selectByMouse: true
                                color: pal.fg
                                selectionColor: pal.accent
                                font.family: pal.fam; font.pixelSize: 12
                                text: root.wpDirEff
                                onAccepted: { root.wpSetDir(text); wpGrid.forceActiveFocus(); }
                                Connections { target: root; function onWpDirEffChanged() { dirInput.text = root.wpDirEff; } }
                            }
                        }
                    }
                    // ── search + status ──
                    Rectangle {
                        id: wpSearchBox
                        x: 22; y: 54
                        width: Math.min(260, parent.width * 0.4); height: 28; radius: 10
                        color: pal.tile
                        border.width: 1
                        border.color: wpSearch.activeFocus ? pal.accent : pal.tileBorder
                        Glyph { x: 9; anchors.verticalCenter: parent.verticalCenter; width: 13; height: 13; kind: "search"; color: pal.fg2 }
                        TextInput {
                            id: wpSearch
                            anchors.fill: parent
                            anchors.leftMargin: 30; anchors.rightMargin: 26
                            verticalAlignment: TextInput.AlignVCenter
                            clip: true
                            selectByMouse: true
                            color: pal.fg
                            selectionColor: pal.accent
                            font.family: pal.fam; font.pixelSize: 12
                            onTextChanged: if (root.wpQuery !== text) root.wpQuery = text
                            Keys.onDownPressed: wpGrid.forceActiveFocus()
                            Keys.onReturnPressed: {
                                if (root.wpShown.length > 0) { root.wpApply(root.wpShown[Math.max(0, wpGrid.currentIndex)].path); root.wpOpen = false; }
                            }
                            Text {
                                visible: wpSearch.text === "" && !wpSearch.activeFocus
                                anchors.verticalCenter: parent.verticalCenter
                                text: Language.I18n.text("common.search")
                                color: pal.fg3
                                font.family: pal.fam; font.pixelSize: 12
                            }
                        }
                        Rectangle {
                            visible: root.wpQuery !== ""
                            anchors.right: parent.right; anchors.rightMargin: 6
                            anchors.verticalCenter: parent.verticalCenter
                            width: 16; height: 16; radius: 8
                            color: pal.btnOff
                            Text { anchors.centerIn: parent; text: "\u00d7"; color: pal.fg; font.pixelSize: 12 }
                            MouseArea { anchors.fill: parent; onClicked: { root.wpQuery = ""; wpGrid.forceActiveFocus(); } }
                        }
                    }
                    Text {
                        id: wpSub
                        anchors.left: wpSearchBox.right; anchors.leftMargin: 14
                        anchors.right: parent.right; anchors.rightMargin: 22
                        y: 54; height: 28
                        verticalAlignment: Text.AlignVCenter
                        elide: Text.ElideRight
                        text: root.wpStatus !== "" ? root.wpStatus
                              : (root.wpShown.length + (root.wpShown.length === 1 ? " image" : " images")
                                 + ((root.wallpaperFavs || []).length > 0 ? "  \u00b7  \u2605 first" : "")
                                 + Language.I18n.text("ui.t_aca2e414ec5c"))
                        color: pal.fg3
                        font.family: pal.fam; font.pixelSize: 11
                    }

                    // ── grid ──
                    GridView {
                        id: wpGrid
                        x: 16; y: 94
                        width: parent.width - 38; height: parent.height - 94 - 14
                        clip: true
                        readonly property int cols: Math.max(2, Math.floor(width / 210))
                        cellWidth: Math.floor(width / cols)
                        cellHeight: Math.round(cellWidth * 0.64)
                        model: root.wpShown
                        currentIndex: 0
                        keyNavigationEnabled: true
                        highlightMoveDuration: 0
                        Keys.onPressed: event => {
                            var ok = currentIndex >= 0 && currentIndex < root.wpShown.length;
                            if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && ok) {
                                root.wpApply(root.wpShown[currentIndex].path); root.wpOpen = false; event.accepted = true;
                            } else if (event.key === Qt.Key_Space && ok) {
                                root.wpToggleFav(root.wpShown[currentIndex].path); event.accepted = true;
                            } else if (event.key === Qt.Key_Slash || (event.text.length === 1 && event.text > " " && event.text !== "\u007f"
                                       && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)))) {
                                // typing anywhere starts a search
                                wpSearch.forceActiveFocus();
                                if (event.key !== Qt.Key_Slash) root.wpQuery += event.text;
                                wpSearch.cursorPosition = wpSearch.length;
                                event.accepted = true;
                            }
                        }

                        delegate: Item {
                            id: wc
                            required property int index
                            required property var modelData
                            width: wpGrid.cellWidth; height: wpGrid.cellHeight
                            readonly property bool sel: wpGrid.currentIndex === index
                            readonly property bool cur: modelData.video ? root.wallpaperVideo === modelData.path
                                                                        : (root.wallpaperVideo === "" && root.wallpaperPath === modelData.path)
                            Item {
                                id: wcBox
                                anchors.fill: parent
                                anchors.margins: 5
                                Item {
                                    id: wcMask
                                    anchors.fill: parent
                                    visible: false
                                    layer.enabled: true
                                    layer.smooth: true
                                    Rectangle { anchors.fill: parent; radius: 12; color: "black" }
                                }
                                Item {
                                    anchors.fill: parent
                                    layer.enabled: true
                                    layer.smooth: true
                                    layer.effect: MultiEffect {
                                        maskEnabled: true
                                        maskSource: wcMask
                                        maskThresholdMin: 0.5
                                        maskSpreadAtMin: 1.0
                                    }
                                    Rectangle { anchors.fill: parent; color: pal.btnOff }
                                    Image {
                                        anchors.fill: parent
                                        source: root.fileUrl(wc.modelData.video ? wc.modelData.thumb : wc.modelData.path)
                                        sourceSize.width: 420
                                        fillMode: Image.PreserveAspectCrop
                                        asynchronous: true
                                        cache: true
                                        smooth: true
                                    }
                                    Rectangle {
                                        anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                                        height: 26
                                        color: Qt.rgba(0, 0, 0, 0.5)
                                        opacity: (wc.sel || wcMa.containsMouse) ? 1 : 0
                                        Behavior on opacity { NumberAnimation { duration: 120 } }
                                        Text {
                                            anchors.fill: parent
                                            anchors.leftMargin: 10; anchors.rightMargin: 36
                                            verticalAlignment: Text.AlignVCenter
                                            elide: Text.ElideRight
                                            text: wc.modelData.name
                                            color: "white"
                                            font.family: pal.fam; font.pixelSize: 11
                                        }
                                    }
                                    // animated wallpaper: its looping preview plays while hovered or selected
                                    Loader {
                                        anchors.fill: parent
                                        active: wc.modelData.video && wc.modelData.preview !== "" && (wcMa.containsMouse || wc.sel) && root.wpOpen
                                        sourceComponent: AnimatedImage {
                                            source: root.fileUrl(wc.modelData.preview)
                                            fillMode: Image.PreserveAspectCrop
                                            asynchronous: true
                                            cache: false
                                            playing: true
                                        }
                                    }
                                    Rectangle {
                                        visible: wc.modelData.video
                                        x: 8; y: 8
                                        width: wcBadge.implicitWidth + 14; height: 20; radius: 10
                                        color: Qt.rgba(0, 0, 0, 0.5)
                                        Text {
                                            id: wcBadge
                                            anchors.centerIn: parent
                                            text: Language.I18n.text("ui.t_65fed84e8225")
                                            color: "white"
                                            font.family: pal.fam; font.pixelSize: 10; font.weight: Font.DemiBold
                                        }
                                    }
                                }
                                // selection / current-wallpaper ring
                                Rectangle {
                                    anchors.fill: parent
                                    radius: 12
                                    color: "transparent"
                                    border.width: wc.sel ? 3 : (wc.cur ? 2 : 0)
                                    border.color: wc.sel ? pal.accent : "white"
                                }
                                MouseArea {
                                    id: wcMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onPositionChanged: wpGrid.currentIndex = wc.index      // real mouse movement only, so the keyboard keeps control
                                    onClicked: { root.wpApply(wc.modelData.path); root.wpOpen = false; }
                                }
                                // favourite star
                                Rectangle {
                                    anchors.right: parent.right; anchors.top: parent.top
                                    anchors.margins: 7
                                    width: 26; height: 26; radius: 13
                                    visible: wc.modelData.fav || wcMa.containsMouse || wcStarMa.containsMouse
                                    color: Qt.rgba(0, 0, 0, wcStarMa.containsMouse ? 0.62 : 0.45)
                                    Text {
                                        anchors.centerIn: parent
                                        text: wc.modelData.fav ? "\u2605" : "\u2606"
                                        color: wc.modelData.fav ? "#ffd60a" : "white"
                                        font.pixelSize: 15
                                    }
                                    MouseArea {
                                        id: wcStarMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        onClicked: root.wpToggleFav(wc.modelData.path)
                                    }
                                }
                            }
                        }
                    }
                    // ── scrollbar ──
                    Item {
                        id: wpTrack
                        visible: wpGrid.contentHeight > wpGrid.height + 1
                        x: parent.width - 16; y: wpGrid.y + 2
                        width: 10; height: wpGrid.height - 4
                        readonly property real ratio: Math.min(1, wpGrid.visibleArea.heightRatio)
                        readonly property real thumbH: Math.max(32, ratio * height)
                        readonly property real maxY: Math.max(1, height - thumbH)
                        Rectangle { anchors.horizontalCenter: parent.horizontalCenter; width: 4; height: parent.height; radius: 2; color: pal.track; opacity: 0.6 }
                        MouseArea {                      // click the track to jump
                            anchors.fill: parent
                            onPressed: mouse => wpTrack.jumpTo(mouse.y - wpTrack.thumbH / 2)
                        }
                        function jumpTo(ty) {
                            var f = Math.max(0, Math.min(1, ty / wpTrack.maxY));
                            wpGrid.contentY = wpGrid.originY + f * Math.max(0, wpGrid.contentHeight - wpGrid.height);
                        }
                        Rectangle {
                            id: wpThumb
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: wpThumbMa.containsMouse || wpThumbMa.drag.active ? 7 : 5
                            height: wpTrack.thumbH
                            radius: width / 2
                            color: wpThumbMa.drag.active ? pal.fg2 : pal.fg3
                            Behavior on width { NumberAnimation { duration: 100 } }
                            Binding {
                                target: wpThumb; property: "y"
                                when: !wpThumbMa.drag.active
                                value: (1 - wpTrack.ratio) > 0.0001 ? Math.max(0, Math.min(wpTrack.maxY, wpGrid.visibleArea.yPosition / (1 - wpTrack.ratio) * wpTrack.maxY)) : 0
                            }
                            MouseArea {
                                id: wpThumbMa
                                anchors.fill: parent
                                anchors.margins: -4
                                hoverEnabled: true
                                drag.target: wpThumb
                                drag.axis: Drag.YAxis
                                drag.minimumY: 0
                                drag.maximumY: wpTrack.maxY
                                onPositionChanged: if (drag.active) wpTrack.jumpTo(wpThumb.y)
                            }
                        }
                    }
                    Text {
                        visible: root.wpShown.length === 0
                        anchors.centerIn: parent
                        width: parent.width - 80
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                        text: root.wpQuery !== "" ? Language.I18n.text("ui.t_6d5ac65d3615") + root.wpQuery + "\u201d"
                              : Language.I18n.text("ui.t_40d3cf7206a5") + root.wpDirEff + Language.I18n.text("ui.t_e7bc2e7127b4")
                        color: pal.fg2
                        font.family: pal.fam; font.pixelSize: 13
                    }
                }
            }
        }

        // ═════════ Spotlight lives in its OWN layer (namespace "macspot") ═════════
        // niri blurs a whole layer or none of it, so Spotlight has its own layer: put the blur layerrule on
        // "macspot" and leave "macbar" without blur.
        PanelWindow {
            id: spotWin
            property var glassSurfaces: []
            BackgroundEffect.blurRegion: GlassRegion { host: spotWin }
            screen: perScreen.modelData
            // The layer stays mapped: creating / destroying it on every open restarted the glass's window captures and
            // niri's layer animation, which is what made Spotlight flicker or vanish. Closed = invisible + click-through.
            visible: root.spotlightEnabled
            readonly property bool openish: ui.pop === "spot" || spot.vis > 0
            onOpenishChanged: root.popCount += (openish ? 1 : -1)     // keeps the window-geometry poller running while Spotlight is open
            mask: Region { item: spotWin.openish ? spotRoot : spotNoInput }
            Item { id: spotNoInput; width: 0; height: 0 }
            anchors { left: true; right: true; top: true; bottom: true }
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore

            WlrLayershell.namespace: "macspot"
            WlrLayershell.layer: WlrLayer.Top
            WlrLayershell.keyboardFocus: ui.pop === "spot" ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

            Item {
                id: spotRoot
                anchors.fill: parent

                Loader {
                    id: spotBackdrop
                    active: root.liquidActive
                    sourceComponent: backdropComp
                    onLoaded: { item.hostShown = Qt.binding(function () { return !root.gaming && spotWin.openish; });
                                item.region = Qt.binding(function () { return Qt.rect(spot.x - 128, spot.y - 128, spot.width + 256, spot.height + 256); }); }
                }

                // a clipboard entry being dragged out of Spotlight
                Item {
                    id: clipGhost
                    z: 50
                    property var en: null
                    property real px: 0
                    property real py: 0
                    property real zoom: 1
                    property real wob: 0
                    property real homeX: 0
                    property real homeY: 0
                    visible: en !== null
                    width: 220; height: en && en.kind === "image" ? 150 : 64
                    x: px - width / 2; y: py - height / 2
                    scale: zoom; rotation: wob
                    function start(e) { en = e; zoom = 1.06; opacity = 1; homeX = px; homeY = py; wiggleClip.restart(); }
                    function drop(out) {
                        wiggleClip.stop();
                        if (out) { clipLaunch.restart(); }
                        else { clipBack.restart(); }
                    }
                    Rectangle {
                        anchors.fill: parent; radius: 14
                        color: root.darkMode ? Qt.rgba(0.16, 0.16, 0.18, 0.92) : Qt.rgba(0.97, 0.97, 0.98, 0.95)
                        border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.18)
                    }
                    Image {
                        visible: clipGhost.en && clipGhost.en.kind === "image"
                        anchors.fill: parent; anchors.margins: 6
                        source: clipGhost.en && clipGhost.en.thumb ? clipGhost.en.thumb : ""
                        fillMode: Image.PreserveAspectCrop; asynchronous: true
                    }
                    Text {
                        visible: !(clipGhost.en && clipGhost.en.kind === "image")
                        anchors.fill: parent; anchors.margins: 12
                        text: clipGhost.en ? clipGhost.en.text : ""
                        wrapMode: Text.Wrap; elide: Text.ElideRight; maximumLineCount: 2
                        color: root.darkMode ? "white" : "#1d1d1f"; font.family: root.fontFamily; font.pixelSize: 13
                    }
                    SequentialAnimation {
                        id: wiggleClip; loops: Animation.Infinite
                        NumberAnimation { target: clipGhost; property: "wob"; to: 3; duration: 90; easing.type: Easing.InOutSine }
                        NumberAnimation { target: clipGhost; property: "wob"; to: -3; duration: 180; easing.type: Easing.InOutSine }
                        NumberAnimation { target: clipGhost; property: "wob"; to: 0; duration: 90; easing.type: Easing.InOutSine }
                    }
                    SequentialAnimation {
                        id: clipLaunch
                        ParallelAnimation {
                            NumberAnimation { target: clipGhost; property: "zoom"; to: 2.2; duration: 460; easing.type: Easing.OutQuint }
                            NumberAnimation { target: clipGhost; property: "opacity"; to: 0; duration: 460; easing.type: Easing.OutCubic }
                            NumberAnimation { target: clipGhost; property: "wob"; to: 0; duration: 200 }
                        }
                        ScriptAction { script: { var e = clipGhost.en; clipGhost.en = null; ui.pop = ""; if (e) root.clipOpen(e); } }
                    }
                    SequentialAnimation {
                        id: clipBack
                        ParallelAnimation {
                            NumberAnimation { target: clipGhost; property: "px"; to: clipGhost.homeX; duration: 380; easing.type: Easing.OutQuint }
                            NumberAnimation { target: clipGhost; property: "py"; to: clipGhost.homeY; duration: 380; easing.type: Easing.OutQuint }
                            NumberAnimation { target: clipGhost; property: "wob"; to: 0; duration: 200 }
                            NumberAnimation { target: clipGhost; property: "opacity"; to: 0; duration: 380; easing.type: Easing.InCubic }
                        }
                        ScriptAction { script: clipGhost.en = null }
                    }
                }

                // click outside Spotlight closes it
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.AllButtons
                    onPressed: ui.pop = ""
                }

                // Backdrop capture + blur for Spotlight's glass. Deliberately NOT inside `spot`: as children they inherited
                // spot's opacity while it faded, so the glass refracted a half-transparent backdrop and turned into a milky
                // blob mid-fade (the fade looked broken). Out here they always produce the real backdrop.
                MappedRect {
                    id: spotMapping
                    sourceItem: spot; targetItem: spotBackdrop.item
                    localRect: Qt.rect(-128, -128, spot.width + 256, 684)
                }
                ShaderEffectSource {
                    id: spSrc
                    sourceItem: spotBackdrop.item     // wallpaper + live windows, captured inside this layer
                    hideSource: true
                    live: spotWin.openish
                    visible: false
                    sourceRect: spotMapping.rect
                }
                MultiEffect {
                    id: spBlurFx
                    source: spSrc
                    width: spSrc.sourceRect.width; height: spSrc.sourceRect.height
                    blurEnabled: spg.blur * spg.blurMul > 0
                    blurMax: 6
                    blur: Math.min(1.0, (spg.blur * spg.blurMul) * 1.4 / 6.0)
                    autoPaddingEnabled: false
                    visible: false
                }
                // real Gaussian pre-blur of the backdrop (Qt MultiEffect): the glass shader refracts THIS texture,
                // so there are no sampled copies of the background any more
                ShaderEffectSource {
                    id: spBlur
                    sourceItem: spBlurFx
                    live: spotWin.openish
                    visible: false
                }
                MultiEffect {
                    id: spBlur2Fx
                    source: spBlur
                    width: spSrc.sourceRect.width; height: spSrc.sourceRect.height
                    blurEnabled: true
                    blurMax: 64
                    blur: Math.max(0.0, Math.min(1.0, (spg.blur * spg.blurMul) * 1.4 / 64.0 - 1.0))
                    autoPaddingEnabled: false
                    visible: false
                }
                // second Gaussian pass: stacks on the first one so Spotlight can blur past a single pass's 64 px limit
                ShaderEffectSource {
                    id: spBlur2
                    sourceItem: spBlur2Fx
                    live: spotWin.openish
                    visible: false
                }
                GlassCtx {
                    id: spg
                    src: spBlur2
                    srcRect: spSrc.sourceRect
                    frame: spotRoot
                    liquid: root.liquidActive
                    shaderUrl: root.glassShaderUrl
                    dark: root.effDark
                    tint: root.glassOpacity
                    strength: root.glassLiquid * 0.6        // Spotlight: gentler refraction than the Dock
                    rim: root.glassRim * 0.4                 // and a subtle rim (no heavy outline)
                    grain: root.glassGrain
                    blur: root.glassBlur
                    blurMul: 12.0                   // Spotlight: strong smooth blur (two stacked Gaussian passes); lower to soften, raise to blur more
                    debug: root.glassDebug
                    onFailed: root.glassState = "failed"
                }

                // ═════════ Spotlight (Liquid Glass) ═════════
                Item {
                    id: spot
                    z: 10
                    width: 640
                    readonly property var curPanel: ui.spMode === "apps" ? appsPanel : (ui.spMode === "clip" ? clipPanel : emojiPanel)
                    height: ui.spFull ? curPanel.height : (resPanel.visible ? resPanel.y + resPanel.height : spRow.height)
                    x: Math.round((spotRoot.width - width) / 2)
                    // the search pill sits a little above the vertical centre of the screen (0.4 of the height; 0.5 = dead centre); the Applications panel centres itself instead
                    y: Math.round(spotRoot.height * 0.4 - (ui.spFull ? curPanel.height / 2 : 24))
                    Behavior on y { enabled: spot.vis > 0.99; NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                    // opens with a springy pop; dismiss: quick fade + shrink
                    property real vis: 0
                    opacity: vis
                    visible: vis > 0.001
                    scale: ui.spCalm ? 0.98 : 0.94
                    transformOrigin: Item.Center
                    states: State {
                        name: "open"
                        when: ui.pop === "spot"
                        PropertyChanges { target: spot; vis: 1; scale: 1 }
                    }
                    transitions: [
                        Transition {
                            from: ""; to: "open"
                            ParallelAnimation {
                                NumberAnimation { property: "vis"; duration: 520; easing.type: Easing.OutCubic }
                                NumberAnimation { property: "scale"; duration: ui.spCalm ? 460 : 580; easing.type: Easing.OutQuint }
                            }
                        },
                        Transition {
                            from: "open"; to: ""
                            ParallelAnimation {
                                NumberAnimation { property: "vis"; duration: 400; easing.type: Easing.OutCubic }
                                NumberAnimation { property: "scale"; to: 0.95; duration: 400; easing.type: Easing.OutCubic }
                            }
                        }
                    ]

                    Timer { id: spHoverClear; interval: 350; onTriggered: ui.spHoverLabel = "" }
                    Timer {
                        id: spFocusTimer
                        interval: 60
                        onTriggered: (ui.spMode === "apps" ? appsInput : (ui.spMode === "clip" ? clipInput : (ui.spMode === "emoji" ? emojiInput : spInput))).forceActiveFocus()
                    }

                    // ── search pill + the four round buttons ──
                    Row {
                        id: spRow
                        spacing: 12
                        opacity: !ui.spFull ? 1 : 0
                        visible: opacity > 0
                        Behavior on opacity { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }

                        Item {
                            id: spPill
                            width: spot.width - 5 * 60
                            height: 48
                            GGlass { anchors.fill: parent; gx: spg; cornerR: 24; thickness: 18; strengthMul: 0.7; shadowAmt: 0.18 }
                            HoverHandler { id: pillHover }
                            ContourGlow { cornerR: 24; hovered: pillHover.hovered; at: pillHover.point.position; glowColor: root.darkMode ? "white" : root.accent }
                            // very thin outline
                            Rectangle {
                                anchors.fill: parent; radius: 24; color: "transparent"; antialiasing: true
                                border.width: 1; border.color: root.darkMode ? Qt.rgba(1, 1, 1, 0.16) : Qt.rgba(0, 0, 0, 0.11)
                            }
                            Glyph {
                                x: 18; anchors.verticalCenter: parent.verticalCenter
                                width: 18; height: 18
                                kind: "search"; color: pal.fg2
                            }
                            // placeholder: blur-morphs between "Spotlight Search" and the hovered button's name
                            MorphText {
                                x: spInput.x + 3
                                width: spInput.width
                                anchors.verticalCenter: parent.verticalCenter
                                visible: spInput.text === ""
                                animateWidth: false
                                duration: 460
                                blurMax: 48
                                text: ui.spHoverLabel !== "" ? ui.spHoverLabel : Language.I18n.text("ui.t_296cb158c0e5")
                                color: pal.fg2
                                font.family: pal.fam; font.pixelSize: 17
                                elide: Text.ElideRight
                            }
                            TextInput {
                                id: spInput
                                x: 46
                                width: parent.width - 46 - 18
                                anchors.verticalCenter: parent.verticalCenter
                                clip: true
                                color: pal.fg
                                selectionColor: root.accent
                                selectedTextColor: "white"
                                font.family: pal.fam; font.pixelSize: 17
                                horizontalAlignment: /[\u0590-\u08ff]/.test(text) ? Text.AlignRight : Text.AlignLeft
                                onTextChanged: { if (!ui.spFull) { resPanel.pointerSelection = false; ui.spCloseActions(); ui.spQuery = text; ui.spSel = 0; ui.armed = ""; if (/^(file|find)\s+/i.test(text)) root.updateFileSearch(text.replace(/^(file|find)\s+/i, "").trim()); } }
                                Keys.onPressed: event => ui.spKey(event)
                            }
                        }
                        Repeater {
                            model: [
                                { k: "appstore", id: "apps", label: "Apps" }, { k: "folder", id: "files", label: Language.I18n.text("ui.t_abc7e9892806") },
                                { k: "layers", id: "actions", label: Language.I18n.text("ui.t_ff8059dc6752") }, { k: "clipboard", id: "clip", label: Language.I18n.text("ui.t_285d69f0c5d1") }, { k: "smile", id: "emoji", label: Language.I18n.text("ui.t_61ad8976e650") }
                            ]
                            delegate: CCBtn {
                                required property var modelData
                                t: pal; gx: spg
                                d: 48
                                bounce: true
                                shadow: 0.18
                                kind: modelData.k
                                on: ui.spMode === modelData.id
                                HoverHandler {
                                    id: btnHover
                                    // crossing the gap to the next button must not flash "Spotlight Search": only go back
                                    // to it once the pointer has been off every button for 0.35 s
                                    onHoveredChanged: {
                                        if (hovered) { spHoverClear.stop(); ui.spHoverLabel = modelData.label; }
                                        else if (ui.spHoverLabel === modelData.label) spHoverClear.restart();
                                    }
                                }
                                ContourGlow { cornerR: 24; hovered: btnHover.hovered; at: btnHover.point.position; glowColor: root.darkMode ? "white" : root.accent }
                                // very thin outline
                                Rectangle {
                                    anchors.fill: parent; radius: width / 2; color: "transparent"; antialiasing: true
                                    border.width: 1; border.color: root.darkMode ? Qt.rgba(1, 1, 1, 0.16) : Qt.rgba(0, 0, 0, 0.11)
                                }
                                onClicked: {
                                    if (modelData.id === "apps") ui.spSetMode(ui.spMode === "apps" ? "home" : "apps");
                                    else if (modelData.id === "actions") ui.spSetMode(ui.spMode === "actions" ? "home" : "actions");
                                    else if (modelData.id === "files") { ui.pop = ""; root.sh("dolphin \"$HOME\""); }
                                    else if (modelData.id === "clip") ui.spSetMode(ui.spMode === "clip" ? "home" : "clip");
                                    else ui.spSetMode(ui.spMode === "emoji" ? "home" : "emoji");
                                }
                            }
                        }
                    }

                    // ── results under the pill ──
                    Item {
                        id: resPanel
                        y: spRow.height + 10
                        width: spot.width
                        readonly property var items: ui.spFull ? [] : ui.spList()      // clipboard / emoji / apps have their own panels; actions replace the list
                        property bool pointerSelection: false
                        property int keep: 1                         // last non-empty row count, so the panel shrinks while it fades out
                        onItemsChanged: {
                            if (items.length > 0) keep = items.length;
                            // Keep existing delegates (and their mouse grabs) when search data changes.
                            while (resultRows.count < items.length) resultRows.append({});
                            while (resultRows.count > items.length) resultRows.remove(resultRows.count - 1);
                        }
                        ListModel { id: resultRows }
                        readonly property int selIdx: Math.max(0, Math.min(ui.spSel, items.length - 1))
                        opacity: (!ui.spFull && items.length > 0) ? 1 : 0
                        visible: opacity > 0
                        Behavior on opacity { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                        height: (items.length > 0 ? items.length : keep) * 46 + 16
                        Behavior on height { NumberAnimation { duration: 320; easing.type: Easing.OutQuint } }
                        GGlass { anchors.fill: parent; gx: spg; cornerR: 26; thickness: 22; strengthMul: 0.75; shadowAmt: 0.22 }
                        Item {
                            x: 8; y: 8
                            width: parent.width - 16
                            height: parent.height - 16
                            clip: true
                            Rectangle {
                                y: resPanel.selIdx * 46
                                width: parent.width; height: 46; radius: 16
                                color: (resPanel.items[resPanel.selIdx] && resPanel.items[resPanel.selIdx].confirm === true
                                        && ui.armed === resPanel.items[resPanel.selIdx].title) ? "#FF453A" : root.accent
                                Behavior on y { enabled: !resPanel.pointerSelection; NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                                Behavior on color { ColorAnimation { duration: 120 } }
                            }
                        Column {
                            width: parent.width
                            Repeater {
                                model: resultRows
                                delegate: Item {
                                    id: rr
                                    required property int index
                                    readonly property var modelData: resPanel.items[index] || ({})
                                    readonly property string ico: (modelData && modelData.icon) ? String(modelData.icon) : ""
                                    readonly property bool sel: index === Math.min(ui.spSel, resPanel.items.length - 1)
                                    readonly property bool armedNow: modelData.confirm === true && ui.armed === modelData.title
                                    readonly property bool hasActions: !ui.spActionItem && SettingsSearch.hasExtras(modelData.kind)
                                    readonly property bool disabledAction: ui.spActionItem && modelData.enabled === false
                                    width: parent.width
                                    height: 46
                                    Drag.dragType: Drag.Automatic
                                    Drag.supportedActions: Qt.CopyAction
                                    Drag.proposedAction: Qt.CopyAction
                                    Drag.hotSpot.x: width / 2
                                    Drag.hotSpot.y: height / 2
                                    Accessible.role: Accessible.Button
                                    Accessible.name: modelData.title || ""
                                    Accessible.description: modelData.sub || ""
                                    Accessible.onPressAction: ui.spActivate(rr.index)
                                    Item {
                                        x: 12
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 30; height: 30
                                        Image {
                                            visible: rr.ico !== ""
                                            anchors.fill: parent
                                            source: rr.ico
                                            sourceSize: Qt.size(64, 64)
                                            fillMode: Image.PreserveAspectFit
                                            asynchronous: true
                                            smooth: true
                                        }
                                        Glyph {
                                            visible: rr.ico === ""
                                            anchors.centerIn: parent
                                            width: 20; height: 20
                                            kind: (rr.modelData && rr.modelData.glyph) ? rr.modelData.glyph : ""
                                            color: rr.sel ? "white" : pal.fg
                                        }
                                    }
                                    Text {
                                        x: 54
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: parent.width - 54 - (rr.hasActions && rr.sel ? 168 : 140)
                                        elide: Text.ElideRight
                                        opacity: rr.disabledAction ? 0.45 : 1
                                        text: rr.armedNow ? (rr.modelData.confirmLabel || Language.I18n.text("ui.t_56af92f92b20")) : (rr.modelData.title || "")
                                        color: rr.sel ? "white" : pal.fg
                                        font.family: pal.fam; font.pixelSize: 14
                                    }
                                    Text {
                                        anchors.right: parent.right
                                        anchors.rightMargin: rr.hasActions && rr.sel ? 44 : 16
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: Math.min(implicitWidth, 120)
                                        elide: Text.ElideRight
                                        text: rr.modelData.sub || ""
                                        color: rr.sel ? Qt.rgba(1, 1, 1, 0.8) : pal.fg2
                                        font.family: pal.fam; font.pixelSize: 12
                                    }
                                    Text {
                                        visible: rr.hasActions && rr.sel
                                        anchors.right: parent.right
                                        anchors.rightMargin: 14
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: "›"
                                        color: "white"
                                        font.pixelSize: 22
                                    }
                                    MouseArea {
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                                        property string pressedResult: ""
                                        property bool dragging: false
                                        property real pressX: 0
                                        property real pressY: 0
                                        readonly property bool canDrag: rr.modelData && rr.modelData.kind === "file" && SettingsSearch.isLocalPath(rr.modelData.path)
                                        function resultKey(item) { return JSON.stringify([item.title, item.sub, item.icon, item.glyph, item.kind, item.path || ""]); }
                                        onEntered: { resPanel.pointerSelection = true; ui.spSel = rr.index; }
                                        onPressed: mouse => {
                                            pressedResult = resultKey(rr.modelData);
                                            dragging = false;
                                            pressX = mouse.x;
                                            pressY = mouse.y;
                                        }
                                        onPositionChanged: mouse => {
                                            if (dragging || !pressed || !canDrag || mouse.buttons !== Qt.LeftButton) return;
                                            if (Math.abs(mouse.x - pressX) < 10 && Math.abs(mouse.y - pressY) < 10) return;
                                            dragging = true;
                                            rr.Drag.mimeData = { "text/uri-list": QuickLook.uriList(rr.modelData.path) };
                                            rr.Drag.active = true;
                                        }
                                        onCanceled: {
                                            if (rr.Drag.active) rr.Drag.active = false;
                                            dragging = false;
                                        }
                                        onClicked: mouse => {
                                            if (dragging) { dragging = false; return; }
                                            if (mouse.button === Qt.RightButton) { ui.spOpenActions(rr.modelData); return; }
                                            if (pressedResult === resultKey(rr.modelData)) ui.spActivate(rr.index);
                                        }
                                    }
                                    MouseArea {
                                        visible: rr.hasActions
                                        z: 1
                                        anchors.right: parent.right
                                        width: 40; height: parent.height
                                        hoverEnabled: true
                                        Accessible.name: Language.I18n.text("spotlight.more_actions")
                                        onClicked: ui.spOpenActions(rr.modelData)
                                    }
                                }
                            }
                        }
                        }
                    }

                    // ── Clipboard history panel (macOS Tahoe style) ──
                    Item {
                        id: clipPanel
                        opacity: ui.spMode === "clip" ? 1 : 0
                        visible: opacity > 0
                        scale: ui.spMode === "clip" ? 1 : 0.96
                        transformOrigin: Item.Top
                        Behavior on opacity { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                        Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                        width: spot.width
                        readonly property var items: ui.spMode === "clip" ? ui.spResults : []
                        readonly property int rowH: 56
                        readonly property int shown: Math.min(items.length, 7)
                        readonly property string emptyTitle: root.clipState === "missing" ? Language.I18n.text("ui.t_f948efee2fc6")
                            : (!root.clipHistory ? Language.I18n.text("ui.t_98f3c171f27c")
                            : (root.clipLoading && root.clipEntries.length === 0 ? "Loading\u2026"
                            : (ui.spQuery.trim() !== "" ? Language.I18n.text("ui.t_ed805f62bdbf") : Language.I18n.text("ui.t_1c0006ee863c"))))
                        readonly property string emptySub: root.clipState === "missing" ? Language.I18n.text("ui.t_74ae71c81bcb")
                            : (!root.clipHistory ? Language.I18n.text("ui.t_e49c6720db6f")
                            : (ui.spQuery.trim() === "" && !root.clipLoading ? Language.I18n.text("ui.t_1bb86a09457d") : ""))
                        height: 64 + (items.length > 0 ? shown * rowH + 14 : 118)
                        Behavior on height { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                        GGlass { anchors.fill: parent; gx: spg; cornerR: 32; thickness: 30; strengthMul: 0.85; shadowAmt: 0.5 }

                        Item {
                            id: clipHeader
                            x: 20
                            width: parent.width - 40
                            height: 64
                            Rectangle {
                                id: clipChip
                                anchors.verticalCenter: parent.verticalCenter
                                width: 34; height: 34; radius: 10
                                color: root.accent
                                Glyph { anchors.centerIn: parent; width: 20; height: 20; kind: "clipboard"; color: "white" }
                            }
                            Text {
                                id: clipLabel
                                x: 46
                                anchors.verticalCenter: parent.verticalCenter
                                text: Language.I18n.text("ui.t_285d69f0c5d1")
                                color: pal.fg
                                font.family: pal.fam; font.pixelSize: 24; font.weight: Font.Medium
                            }
                            TextInput {
                                id: clipInput
                                x: clipLabel.x + clipLabel.width + 14
                                width: parent.width - x - 48
                                anchors.verticalCenter: parent.verticalCenter
                                clip: true
                                color: pal.fg
                                selectionColor: root.accent
                                selectedTextColor: "white"
                                font.family: pal.fam; font.pixelSize: 24
                                onTextChanged: { if (ui.spMode === "clip") { ui.spQuery = text; ui.spSel = 0; } }
                                Keys.onPressed: event => ui.spKey(event)
                            }
                            CCBtn {
                                t: pal; gx: spg
                                d: 34
                                bounce: true
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                kind: "dots"
                                on: ui.clipMenu
                                onClicked: ui.clipMenu = !ui.clipMenu
                            }
                        }

                        ListView {
                            id: clipListView
                            x: 8; y: 64
                            width: parent.width - 16
                            height: clipPanel.shown * clipPanel.rowH
                            visible: clipPanel.items.length > 0
                            clip: true
                            boundsBehavior: Flickable.StopAtBounds
                            model: clipPanel.items
                            Connections {
                                target: ui
                                function onSpSelChanged() {
                                    if (ui.spHover) { ui.spHover = false; return; }
                                    if (ui.spMode === "clip" && clipPanel.items.length > 0)
                                        clipListView.positionViewAtIndex(Math.min(ui.spSel, clipPanel.items.length - 1), ListView.Contain);
                                }
                            }
                            delegate: Item {
                                id: cr
                                required property var modelData
                                required property int index
                                readonly property bool sel: index === Math.min(ui.spSel, clipPanel.items.length - 1)
                                width: ListView.view.width
                                height: clipPanel.rowH
                                Rectangle {
                                    anchors.fill: parent
                                    anchors.topMargin: 2; anchors.bottomMargin: 2
                                    radius: 16
                                    color: root.accent
                                    opacity: cr.sel ? 1 : 0
                                    Behavior on opacity { NumberAnimation { duration: 90 } }
                                }
                                Item {
                                    x: 14
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 36; height: 36
                                    Rectangle {
                                        visible: cr.modelData.kind === "text" || cr.modelData.kind === "url"
                                        anchors.fill: parent
                                        radius: 10
                                        color: cr.sel ? Qt.rgba(1, 1, 1, 0.22) : (root.darkMode ? Qt.rgba(1, 1, 1, 0.10) : Qt.rgba(0, 0, 0, 0.06))
                                        Glyph {
                                            anchors.centerIn: parent
                                            width: 20; height: 20
                                            kind: cr.modelData.kind === "url" ? "link" : "doc"
                                            color: cr.sel ? "white" : pal.fg2
                                        }
                                    }
                                    Rectangle {
                                        visible: cr.modelData.kind === "color"
                                        anchors.fill: parent
                                        radius: 10
                                        color: cr.modelData.kind === "color" ? cr.modelData.color : "transparent"
                                        border.width: 1; border.color: Qt.rgba(0, 0, 0, 0.25)
                                    }
                                    Item {
                                        visible: cr.modelData.kind === "image"
                                        anchors.fill: parent
                                        Rectangle { anchors.fill: parent; radius: 10; color: root.darkMode ? Qt.rgba(1, 1, 1, 0.10) : Qt.rgba(0, 0, 0, 0.06) }
                                        Image {
                                            anchors.fill: parent
                                            source: cr.modelData.kind === "image" ? cr.modelData.thumb : ""
                                            sourceSize: Qt.size(72, 72)
                                            fillMode: Image.PreserveAspectCrop
                                            asynchronous: true
                                            layer.enabled: true
                                            layer.effect: MultiEffect {
                                                maskEnabled: true
                                                maskSource: thMask
                                                maskThresholdMin: 0.5
                                                maskSpreadAtMin: 1.0
                                            }
                                        }
                                        Item {
                                            id: thMask
                                            anchors.fill: parent
                                            visible: false
                                            layer.enabled: true
                                            Rectangle { anchors.fill: parent; radius: 10; color: "black" }
                                        }
                                    }
                                }
                                Text {
                                    x: 62; y: 9
                                    width: parent.width - 62 - 56
                                    elide: Text.ElideRight
                                    text: cr.modelData ? cr.modelData.title : ""
                                    color: cr.sel ? "white" : pal.fg
                                    font.family: pal.fam; font.pixelSize: 14
                                }
                                Text {
                                    x: 62; y: 31
                                    width: parent.width - 62 - 56
                                    elide: Text.ElideRight
                                    text: cr.modelData ? cr.modelData.sub : ""
                                    color: cr.sel ? Qt.rgba(1, 1, 1, 0.8) : pal.fg2
                                    font.family: pal.fam; font.pixelSize: 12
                                }
                                Glyph {
                                    visible: cr.sel
                                    anchors.right: parent.right
                                    anchors.rightMargin: 18
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 18; height: 18
                                    kind: "return"; color: "white"
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    property point press: Qt.point(0, 0)
                                    property bool dragged: false
                                    onEntered: { if (ui.spSel !== cr.index) { ui.spHover = true; ui.spSel = cr.index; } }
                                    onPressed: mouse => { press = mapToItem(spotRoot, mouse.x, mouse.y); dragged = false; }
                                    onPositionChanged: mouse => {
                                        if (!pressed) return;
                                        var p = mapToItem(spotRoot, mouse.x, mouse.y);
                                        if (!dragged && Math.abs(p.x - press.x) + Math.abs(p.y - press.y) > 14) { dragged = true; clipGhost.start(cr.modelData); }
                                        if (dragged) { clipGhost.px = p.x; clipGhost.py = p.y; }
                                    }
                                    onReleased: mouse => {
                                        if (!dragged) return;
                                        var p = mapToItem(spotRoot, mouse.x, mouse.y);
                                        // outside Spotlight = on the desktop → open it; inside → it flies back
                                        var out = p.x < spot.x || p.x > spot.x + spot.width || p.y < spot.y || p.y > spot.y + spot.height;
                                        clipGhost.drop(out);
                                    }
                                    onClicked: if (!dragged) ui.spActivate(cr.index)
                                }
                            }
                        }

                        Column {
                            visible: clipPanel.items.length === 0
                            x: 20; y: 64
                            width: parent.width - 40
                            height: 118
                            spacing: 6
                            topPadding: 30
                            Text {
                                width: parent.width
                                horizontalAlignment: Text.AlignHCenter
                                text: clipPanel.emptyTitle
                                color: pal.fg
                                font.family: pal.fam; font.pixelSize: 15; font.weight: Font.Medium
                            }
                            Text {
                                width: parent.width
                                horizontalAlignment: Text.AlignHCenter
                                wrapMode: Text.WordWrap
                                text: clipPanel.emptySub
                                color: pal.fg2
                                font.family: pal.fam; font.pixelSize: 12
                            }
                        }

                        // the round "..." menu
                        MouseArea { anchors.fill: parent; z: 4; visible: ui.clipMenu; onClicked: ui.clipMenu = false }
                        Item {
                            id: clipMenuPop
                            z: 5
                            visible: ui.clipMenu
                            x: parent.width - width - 20
                            y: 58
                            width: 250
                            height: 3 * 40 + 12
                            GGlass { anchors.fill: parent; gx: spg; cornerR: 20; thickness: 22; strengthMul: 0.8; shadowAmt: 0.6 }
                            Column {
                                x: 6; y: 6
                                width: parent.width - 12
                                Repeater {
                                    model: ["auto", "del", "clear"]
                                    delegate: Item {
                                        id: cm
                                        required property string modelData
                                        width: parent.width; height: 40
                                        readonly property bool armedNow: modelData === "clear" && ui.armed === "clipclear"
                                        Rectangle {
                                            anchors.fill: parent
                                            radius: 14
                                            color: cm.armedNow ? "#FF453A" : root.accent
                                            opacity: cmMa.containsMouse ? 1 : 0
                                        }
                                        Glyph {
                                            visible: cm.modelData === "auto" && root.clipAutoPaste
                                            x: 12; anchors.verticalCenter: parent.verticalCenter
                                            width: 16; height: 16
                                            kind: "check"; color: cmMa.containsMouse ? "white" : pal.fg
                                        }
                                        Text {
                                            x: 38
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: cm.modelData === "auto" ? Language.I18n.text("ui.t_2ceb6ba917f4")
                                                  : (cm.modelData === "del" ? Language.I18n.text("ui.t_6662750e0331")
                                                  : (cm.armedNow ? Language.I18n.text("ui.t_1f8c95036230") : Language.I18n.text("ui.t_9768be40e931")))
                                            color: cmMa.containsMouse ? "white" : ((cm.modelData === "clear") ? "#FF453A" : pal.fg)
                                            font.family: pal.fam; font.pixelSize: 14
                                        }
                                        MouseArea {
                                            id: cmMa
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            onClicked: {
                                                if (cm.modelData === "auto") root.clipAutoPaste = !root.clipAutoPaste;
                                                else if (cm.modelData === "del") {
                                                    var n = clipPanel.items.length;
                                                    if (n > 0) root.clipDelete(clipPanel.items[Math.min(ui.spSel, n - 1)]);
                                                    ui.clipMenu = false;
                                                } else {
                                                    if (ui.armed === "clipclear") { ui.armed = ""; root.clipClear(); ui.clipMenu = false; }
                                                    else ui.armed = "clipclear";
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // ── Emoji panel ──
                    Item {
                        id: emojiPanel
                        opacity: ui.spMode === "emoji" ? 1 : 0
                        visible: opacity > 0
                        scale: ui.spMode === "emoji" ? 1 : 0.96
                        transformOrigin: Item.Top
                        Behavior on opacity { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                        Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                        width: spot.width
                        readonly property int cell: 50
                        readonly property int gridRows: 6
                        readonly property var items: ui.spMode === "emoji" ? ui.spResults : []
                        readonly property var cur: items[Math.min(ui.spSel, items.length - 1)]
                        height: 64 + 42 + gridRows * cell + 46
                        GGlass { anchors.fill: parent; gx: spg; cornerR: 32; thickness: 30; strengthMul: 0.85; shadowAmt: 0.5 }

                        Item {
                            x: 20
                            width: parent.width - 40
                            height: 64
                            Rectangle {
                                id: emojiChip
                                anchors.verticalCenter: parent.verticalCenter
                                width: 34; height: 34; radius: 10
                                color: root.accent
                                Glyph { anchors.centerIn: parent; width: 20; height: 20; kind: "smile"; color: "white" }
                            }
                            Text {
                                id: emojiLabel
                                x: 46
                                anchors.verticalCenter: parent.verticalCenter
                                text: Language.I18n.text("ui.t_61ad8976e650")
                                color: pal.fg
                                font.family: pal.fam; font.pixelSize: 24; font.weight: Font.Medium
                            }
                            TextInput {
                                id: emojiInput
                                x: emojiLabel.x + emojiLabel.width + 14
                                width: parent.width - x
                                anchors.verticalCenter: parent.verticalCenter
                                clip: true
                                color: pal.fg
                                selectionColor: root.accent
                                selectedTextColor: "white"
                                font.family: pal.fam; font.pixelSize: 24
                                onTextChanged: { if (ui.spMode === "emoji") { ui.spQuery = text; ui.spSel = 0; } }
                                Keys.onPressed: event => ui.spKey(event)
                            }
                        }

                        // category tabs
                        Row {
                            x: 20; y: 64
                            opacity: ui.spQuery.trim() === "" ? 1 : 0.35
                            Repeater {
                                model: ["\uD83D\uDD58", "\uD83D\uDE00", "\uD83E\uDDD1", "\uD83D\uDC3B", "\uD83C\uDF54", "\u2708\uFE0F", "\u26BD", "\uD83D\uDCA1", "\uD83D\uDD23", "\uD83C\uDFF3\uFE0F"]
                                delegate: Item {
                                    id: tab
                                    required property string modelData
                                    required property int index
                                    width: 60; height: 36
                                    Rectangle {
                                        anchors.centerIn: parent
                                        width: 48; height: 32; radius: 12
                                        color: root.accent
                                        opacity: (ui.emCat === tab.index && ui.spQuery.trim() === "") ? 0.9 : (tabMa.containsMouse ? 0.25 : 0)
                                        Behavior on opacity { NumberAnimation { duration: 100 } }
                                    }
                                    Text {
                                        anchors.centerIn: parent
                                        text: tab.modelData
                                        font.family: root.emojiFont; font.pixelSize: 22
                                    }
                                    MouseArea {
                                        id: tabMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        onClicked: {
                                            emojiInput.text = "";
                                            ui.emCat = tab.index; ui.spSel = 0;
                                            emojiInput.forceActiveFocus();
                                        }
                                    }
                                }
                            }
                        }

                        GridView {
                            id: emojiGrid
                            x: 20; y: 64 + 42
                            width: ui.emCols * emojiPanel.cell
                            height: emojiPanel.gridRows * emojiPanel.cell
                            cellWidth: emojiPanel.cell
                            cellHeight: emojiPanel.cell
                            clip: true
                            boundsBehavior: Flickable.StopAtBounds
                            model: emojiPanel.items
                            Connections {
                                target: ui
                                function onSpSelChanged() {
                                    if (ui.spHover) { ui.spHover = false; return; }
                                    if (ui.spMode === "emoji" && emojiPanel.items.length > 0)
                                        emojiGrid.positionViewAtIndex(Math.min(ui.spSel, emojiPanel.items.length - 1), GridView.Contain);
                                }
                            }
                            delegate: Item {
                                id: ec
                                required property var modelData
                                required property int index
                                readonly property bool sel: index === Math.min(ui.spSel, emojiPanel.items.length - 1)
                                width: emojiPanel.cell; height: emojiPanel.cell
                                Rectangle {
                                    anchors.centerIn: parent
                                    width: parent.width - 4; height: parent.height - 4
                                    radius: 14
                                    color: root.accent
                                    opacity: ec.sel ? 1 : 0
                                }
                                Text {
                                    anchors.centerIn: parent
                                    text: ec.modelData ? ec.modelData[0] : ""
                                    font.family: root.emojiFont; font.pixelSize: 36
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onEntered: { if (ui.spSel !== ec.index) { ui.spHover = true; ui.spSel = ec.index; } }
                                    onClicked: { ui.pop = ""; root.emojiPick(ec.modelData); }
                                }
                            }
                        }
                        Text {
                            visible: emojiPanel.items.length === 0
                            x: 20; y: 64 + 42
                            width: parent.width - 40
                            height: emojiPanel.gridRows * emojiPanel.cell
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                            text: ui.spQuery.trim() !== "" ? Language.I18n.text("ui.t_ed805f62bdbf") : Language.I18n.text("ui.t_54670f28748a")
                            color: pal.fg2
                            font.family: pal.fam; font.pixelSize: 14
                        }

                        // footer: name of the highlighted emoji
                        Item {
                            x: 20; y: parent.height - 46
                            width: parent.width - 40; height: 46
                            Rectangle { width: parent.width; height: 1; color: pal.sep }
                            Text {
                                x: 4
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - 180
                                elide: Text.ElideRight
                                text: emojiPanel.cur ? (emojiPanel.cur[0] + "  " + Language.I18n.emojiName(emojiPanel.cur[0], emojiPanel.cur[1])) : ""
                                color: pal.fg2
                                font.family: pal.fam; font.pixelSize: 13
                            }
                            Text {
                                anchors.right: parent.right
                                anchors.rightMargin: 4
                                anchors.verticalCenter: parent.verticalCenter
                                text: root.clipAutoPaste ? Language.I18n.text("ui.t_0b865d472eb3") : Language.I18n.text("ui.t_75245254fc6f")
                                color: pal.fg3
                                font.family: pal.fam; font.pixelSize: 12
                            }
                        }
                    }

                    // ── Applications panel ──
                    Item {
                        id: appsPanel
                        opacity: ui.spMode === "apps" ? 1 : 0
                        visible: opacity > 0
                        scale: ui.spMode === "apps" ? 1 : 0.96
                        transformOrigin: Item.Top
                        Behavior on opacity { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                        Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                        width: spot.width
                        height: Math.min(64 + appsCol.height + 14, 520)
                        GGlass { anchors.fill: parent; gx: spg; cornerR: 32; thickness: 30; strengthMul: 0.85; shadowAmt: 0.5 }

                        Item {
                            id: appsHeader
                            x: 24
                            width: parent.width - 48
                            height: 64
                            Glyph {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 24; height: 24
                                kind: "appstore"; color: pal.fg2
                            }
                            Text {
                                x: 40 + 3
                                anchors.verticalCenter: parent.verticalCenter
                                visible: appsInput.text === ""
                                text: Language.I18n.text("ui.t_98e33b0f3104")
                                color: pal.fg3
                                font.family: pal.fam; font.pixelSize: 24
                            }
                            TextInput {
                                id: appsInput
                                x: 40
                                width: parent.width - 40 - 48
                                anchors.verticalCenter: parent.verticalCenter
                                clip: true
                                color: pal.fg
                                selectionColor: root.accent
                                selectedTextColor: "white"
                                font.family: pal.fam; font.pixelSize: 24
                                onTextChanged: { if (ui.spMode === "apps") { ui.spQuery = text; ui.spSel = 0; } }
                                Keys.onPressed: event => ui.spKey(event)
                            }
                            CCBtn {
                                t: pal; gx: spg
                                d: 34
                                bounce: true
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                kind: "dots"
                                onClicked: ui.spSetMode("home")
                            }
                        }

                        Flickable {
                            id: appsFlick
                            y: 64
                            width: parent.width
                            height: parent.height - 64 - 6
                            contentWidth: width
                            contentHeight: appsCol.height + 8
                            clip: true
                            boundsBehavior: Flickable.StopAtBounds

                            Column {
                                id: appsCol
                                x: 24
                                width: appsFlick.width - 48

                                Repeater {
                                    id: appsRep
                                    model: ui.spQuery.trim() === "" ? root.appSections : root.appSearchSection(ui.spQuery)
                                    delegate: Column {
                                        id: sec
                                        required property var modelData
                                        readonly property bool searching: ui.spQuery.trim() !== ""
                                        readonly property bool expanded: searching || ui.spExpanded[modelData.name] === true
                                        readonly property int shown: expanded ? modelData.apps.length : Math.min(5, modelData.apps.length)
                                        width: appsCol.width

                                        Rectangle { width: parent.width; height: 1; color: pal.sep }
                                        Item {
                                            width: parent.width
                                            height: 38
                                            Text {
                                                anchors.verticalCenter: parent.verticalCenter
                                                text: sec.modelData.name
                                                color: pal.fg
                                                font.family: pal.fam; font.pixelSize: 13; font.weight: Font.Bold
                                            }
                                            Text {
                                                visible: !sec.searching && sec.modelData.apps.length > 5
                                                anchors.right: parent.right
                                                anchors.verticalCenter: parent.verticalCenter
                                                text: sec.expanded ? Language.I18n.text("ui.t_0264d7b0ccb8") : Language.I18n.text("ui.t_ba8a80fdd737")
                                                color: root.accent
                                                font.family: pal.fam; font.pixelSize: 12; font.weight: Font.Bold
                                                MouseArea {
                                                    anchors.fill: parent
                                                    anchors.margins: -6
                                                    onClicked: ui.spToggleSection(sec.modelData.name)
                                                }
                                            }
                                        }
                                        Grid {
                                            columns: 5
                                            Repeater {
                                                model: sec.shown
                                                delegate: Item {
                                                    id: cell
                                                    required property int index
                                                    readonly property var e: sec.modelData.apps[index]
                                                    width: appsCol.width / 5
                                                    height: 96
                                                                                                                                                            Rectangle {
                                                        anchors.fill: parent
                                                        anchors.margins: 2
                                                        radius: 16
                                                        color: cma.containsMouse ? pal.hover : "transparent"
                                                    }
                                                    Image {
                                                        anchors.horizontalCenter: parent.horizontalCenter
                                                        y: 10
                                                        width: 56; height: 56
                                                        source: root.iconSrc(cell.e.icon)
                                                        sourceSize: Qt.size(128, 128)
                                                        fillMode: Image.PreserveAspectFit
                                                        asynchronous: true
                                                        smooth: true
                                                    }
                                                    Text {
                                                        y: 72
                                                        width: parent.width - 8
                                                        x: 4
                                                        horizontalAlignment: Text.AlignHCenter
                                                        elide: Text.ElideRight
                                                        text: cell.e.name
                                                        color: pal.fg
                                                        font.family: pal.fam; font.pixelSize: 12
                                                    }
                                                    MouseArea {
                                                        id: cma
                                                        anchors.fill: parent
                                                        hoverEnabled: true
                                                        onClicked: { ui.pop = ""; root.launchApp(cell.e); }
                                                    }
                                                }
                                            }
                                        }
                                        Item { width: 1; height: 10 }
                                    }
                                }
                                Text {
                                    visible: ui.spQuery.trim() !== "" && appsRep.count === 0
                                    width: parent.width
                                    height: 90
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                    text: Language.I18n.text("ui.t_ed805f62bdbf")
                                    color: pal.fg2
                                    font.family: pal.fam; font.pixelSize: 14
                                }
                            }
                        }
                    }
                }

            }
        }
        }
    }
}

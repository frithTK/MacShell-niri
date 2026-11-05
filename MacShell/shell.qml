import QtQuick
import "Locale" as Language
import "GlassPolicy.js" as GlassPolicy
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    Language.LocaleRuntime {}
    // Installations are transactional; reload only after a deliberate restart.
    settings.watchFiles: false
    Scope {
        id: sharedHub

        readonly property var monData: Niri.monitorData
        readonly property var glassClients: Niri.clients.filter(function(w) { return w.geometryKnown; })
        property var wallpaperMap: ({})
        property var bar: macBar
        property var dock: macDock
        property var widgets: macWidgets
        property var clock: clockApp
        property var calculator: calculatorApp
        property var notes: notesApp
        property var stickies: stickiesApp
        property var notesService: sharedNotesService
        property var reminders: remindersApp
        readonly property var translations: Language.I18n
        function openUtility(key) { if (key === "clock") clockApp.open(); else if (key === "calculator") calculatorApp.open(); else if (key === "notes") notesApp.open(); else if (key === "reminders") remindersApp.open(); else if (key === "stickies") stickiesApp.open(); }
        function openSettings(pane) { macDock.openPrefs(pane); }
        property bool barWantsGeo: false
        property bool dockWantsGeo: false
        property bool barWantsWallpaper: false
        property bool dockWantsWallpaper: false
        property bool widgetsWantWallpaper: false
        readonly property bool windowCapture: macDock.windowCapture
        readonly property bool captureQuiet: macBar.recording || macBar.recRun || macBar.mirroring.quiet
        readonly property bool captureHold: macBar.gaming || !windowCapture
        readonly property bool captureCut: captureHold
        readonly property bool glassHold: macBar.gaming || captureQuiet
        readonly property bool previewHold: glassHold || !windowCapture
        property var closingWins: ({})
        property int tlTick: 0
        CapturePolicy {
            id: capturePolicy
            connected: Niri.connected
            gaming: macBar.gaming
            recording: sharedHub.captureQuiet
            windowPreviews: sharedHub.windowCapture
            barGlass: macBar.liquidActive
            dockGlass: macDock.liquidActive
        }
        Binding { target: NiriCapture; property: "enabled"; value: capturePolicy.enabled }
        Connections { target: Niri; function onUpdated() { sharedHub.tlTick++; } }
        function glassReady(output) {
            return GlassPolicy.canRefract(Niri.clients, output, NiriCapture.enabled && NiriCapture.available,
                                          Niri.overview, NiriCapture.frames);
        }
        function tlFor(id) { return Niri.windowMap[String(id)] || null; }
        function refreshWallpaper() { if (!wpProc.running) wpProc.running = true; }
        Component.onCompleted: refreshWallpaper()

        // wallpaper the glass refracts (Noctalia settings.toml -> awww/swww)
        Process {
            id: wpProc
            command: ["python3", Qt.resolvedUrl("niri_wallpaper.py").toString().replace(/^file:\/\//, "")]
            stdout: StdioCollector {
                onStreamFinished: {
                    var m = {}, lines = text.split("\n");
                    for (var i = 0; i < lines.length; i++) {
                        var k = lines[i].indexOf("\t");
                        if (k <= 0) continue;
                        var key = lines[i].substring(0, k).trim(), val = lines[i].substring(k + 1).trim();
                        if (val !== "" && m[key] === undefined) m[key] = val;
                    }
                    if (JSON.stringify(m) !== JSON.stringify(sharedHub.wallpaperMap)) sharedHub.wallpaperMap = m;
                }
            }
        }

        Timer {
            interval: 15000
            repeat: true
            running: true
            onTriggered: sharedHub.refreshWallpaper()
        }
    }

    MacBar { id: macBar; hub: sharedHub }
    MacDock { id: macDock; hub: sharedHub }
    MacWidgets { id: macWidgets; hub: sharedHub }
    JsonService {
        id: sharedNotesService
        script: "notes_service.py"
        arguments: ["--store", (Quickshell.env("MACSHELL_NOTES_DATA_HOME") || Quickshell.env("XDG_DATA_HOME") || Quickshell.env("HOME") + "/.local/share") + "/macshell/notes/notes.sqlite3"]
        enabled: notesApp.controller.enabled || stickiesApp.windows.length > 0
    }
    ClockApp { id: clockApp; hub: sharedHub }
    CalculatorApp { id: calculatorApp; hub: sharedHub }
    NotesApp { id: notesApp; hub: sharedHub }
    StickiesApp { id: stickiesApp; hub: sharedHub }
    RemindersApp { id: remindersApp; hub: sharedHub }
    ThemeCoordinator { bar: macBar; dock: macDock }

    IpcHandler {
        target: "status"
        function state(): string { return JSON.stringify({ connected: Niri.connected, windows: Niri.toplevels.values.length, capture: NiriCapture.available, captureEnabled: NiriCapture.enabled, captureFrames: Object.keys(NiriCapture.frames).length }); }
    }

    // Keep the user's wallpaper when the previous shell is no longer running.
    Variants {
        model: Quickshell.screens
        PanelWindow {
            id: wallpaperWindow
            required property var modelData
            screen: modelData
            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Background
            WlrLayershell.namespace: "macshell-wallpaper"
            color: "#192436"
            readonly property string wallpaper: macBar.wallpaperPath || macDock.wallpaperPath
                || sharedHub.wallpaperMap["wallpaper.monitors." + modelData.name]
                || sharedHub.wallpaperMap["wallpaper.last"] || sharedHub.wallpaperMap["wallpaper.default"] || ""
            Image { anchors.fill: parent; source: wallpaperWindow.wallpaper ? "file://" + wallpaperWindow.wallpaper : ""; fillMode: Image.PreserveAspectCrop; asynchronous: true }
        }
    }

    IpcHandler {
        target: "volume"
        function increase(): void { macBar.setVolume(macBar.volume + .05, true); }
        function decrease(): void { macBar.setVolume(macBar.volume - .05, true); }
        function muteOutput(): void { macBar.toggleMute(true); }
        function muteInput(): void { macBar.toggleMicMute(true); }
    }
    IpcHandler {
        target: "brightness"
        function increase(): void { macBar.setBrightness(macBar.brightness + .05, true); }
        function decrease(): void { macBar.setBrightness(macBar.brightness - .05, true); }
    }
    IpcHandler {
        target: "media"
        function playPause(): void { if (macBar.player) macBar.player.togglePlaying(); }
        function next(): void { if (macBar.player) macBar.player.next(); }
        function previous(): void { if (macBar.player) macBar.player.previous(); }
    }
    IpcHandler {
        target: "session"
        function lock(): void { Quickshell.execDetached(["sh", Quickshell.env("MACSHELL_LOCK_HELPER") || Qt.resolvedUrl("../MacLock/lock-via-ipc.sh").toString().replace(/^file:\/\//, "")]); }
        function menu(): void { macBar.ccRequest(true); }
    }

    // reopen settings even when both the Dock and the Menu Bar are disabled:
    //   qs -c macbar ipc call settings open
    IpcHandler {
        target: "settings"
        function open(): void { macDock.openPrefs("general"); }
        // qs -c MacShell ipc call settings pane wallpaper   (general, dock, menubar, appearance, wallpaper, behavior, apps, about)
        function pane(id: string): void { macDock.openPrefs(id); }
    }
    IpcHandler {
        target: "appearance"
        function theme(mode: string): void { if (["light", "dark"].indexOf(mode) >= 0) macDock.setLook("darkMode", mode === "dark"); }
        function state(): string { return JSON.stringify({dark: macDock.darkMode, barDark: macBar.darkMode, popupDark: macBar.effDark, barInk: macBar.barInks}); }
    }
    IpcHandler {
        target: "bar"
        function layout(): string { return JSON.stringify(macBar.barFrames); }
    }
    // qs -c MacShell ipc call clock open | tab alarms | stop | snooze
    IpcHandler {
        target: "clock"
        function open(): void { clockApp.open(); }
        function tab(name: string): void { clockApp.open(name); }
        function stop(): void { clockApp.stopRing(); }
        function snooze(): void { clockApp.snooze(); }
    }
    IpcHandler {
        target: "calculator"
        function open(): void { calculatorApp.open(); }
        function expression(value: string): void { calculatorApp.open(value); }
    }
    IpcHandler {
        target: "notes"
        function open(): void { notesApp.open(); }
    }
    IpcHandler {
        target: "reminders"
        function open(): void { remindersApp.open(); }
    }
    IpcHandler {
        target: "stickies"
        function open(): void { stickiesApp.open(); }
    }
    IpcHandler {
        target: "utilities"
        function open(name: string): void { sharedHub.openUtility(name); }
    }
    IpcHandler {
        target: "notifications"
        function open(): void { macBar.notifPopRequest(true); }
        function close(): void { macBar.notifPopRequest(false); }
        function clear(): void { macBar.notifClearAnimated(); }
        // the lock screen: a notification swiped away
        function dismiss(id: int): void { macBar.notifDelete(id); macBar.notifUnread = Math.max(0, macBar.notifUnread - 1); }
    }
    // qs -c MacShell ipc call gaming toggle | on | off
    IpcHandler {
        target: "gaming"
        function toggle(): void { macBar.gamingMode = !macBar.gaming; }
        function on(): void { macBar.gamingMode = true; }
        function off(): void { macBar.gamingMode = false; macBar.gamingAutoActive = false; }
    }
    // qs -c <config> ipc call glass captures false   (true to switch window previews back on)
    IpcHandler {
        target: "glass"
        function captures(on: bool): void { macDock.windowCapture = on; }
        function style(component: string, mode: string): void {
            if (["blur", "liquid"].indexOf(mode) < 0) return;
            if (component === "dock") macDock.dockStyle = mode;
            else if (component === "bar") macBar.barStyle = mode;
        }
        function tune(setting: string, value: real): void {
            if (!isFinite(value)) return;
            if (setting === "blur") macDock.setLook("glassBlur", Math.round(Math.max(0, Math.min(80, value))));
            else if (setting === "refraction") macDock.setLook("glassLiquid", Math.max(0, Math.min(2.5, value)));
        }
        function state(): string {
            return JSON.stringify(Quickshell.screens.map(s => ({output: s.name,
                mode: macBar.gaming ? "disabled" : (macBar.liquidActive || macDock.liquidActive) && sharedHub.glassReady(s.name) ? "refraction" : "compositor",
                barStyle: macBar.barStyle, dockStyle: macDock.dockStyle,
                barShader: macBar.glassState, dockShader: macDock.glassState,
                blur: macDock.glassBlur, refraction: macDock.glassLiquid,
                nativeBlur: {available: macDock.nativeBlur.available, managed: macDock.nativeBlur.managed,
                    appliedLevel: macDock.nativeBlur.appliedLevel, error: macDock.nativeBlur.error}})));
        }
    }
    IpcHandler {
        target: "nightshift"
        function toggle(): void { macBar.toggleNightShift(); }
        function on(): void { macBar.nightDesired = true; }
        function off(): void { macBar.nightDesired = false; }
        function temperature(value: int): void { macBar.nightTemp = Math.max(2500, Math.min(6000, value)); }
        function state(): string {
            return JSON.stringify({desired: macBar.nightDesired, enabled: macBar.nightShift.enabled,
                available: macBar.nightShift.available, state: macBar.nightShift.state,
                temperature: macBar.nightTemp, appliedTemperature: macBar.nightShift.appliedTemperature,
                error: macBar.nightShift.error});
        }
    }
    IpcHandler {
        target: "power"
        function open(): void { macBar.power.refresh(); macBar.controlRequested("battery"); }
        function select(profile: string): void { macBar.power.select(profile); }
        function state(): string {
            return JSON.stringify({profile: macBar.power.profile, available: macBar.power.available,
                profiles: macBar.power.profiles, busy: macBar.power.busy, gameHold: macBar.power.gameHold,
                error: macBar.power.error, battery: {present: macBar.battery.present,
                    percentage: macBar.battery.percentage, remaining: macBar.battery.remaining}});
        }
    }
}

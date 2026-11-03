// Clock — the macOS Clock app for MacShell: World Clock, Alarms, Stopwatch, Timers.
//
//   qs -c MacShell ipc call clock open            (also: clock tab alarms|world|stopwatch|timers, clock stop, clock snooze)
//
// A shared service owns Clock state while the shell is running, including when the window is closed.
// The lock screen reads the same saved state.
import QtQuick
import "Locale" as Language
import "ClockDisplay.js" as ClockDisplay
import QtQuick.Controls
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

Scope {
    id: root
    property var hub: null
    property bool appEnabled: true
    readonly property alias backend: clockBackend
    readonly property var dock: hub ? hub.dock : null
    readonly property var bar: hub ? hub.bar : null
    readonly property bool darkMode: dock ? dock.darkMode : true
    readonly property string fam: dock ? dock.fontFamily : "Inter Variable"
    readonly property color accent: dock ? dock.accent : "#0A84FF"
    readonly property bool use24h: bar ? bar.use24h : true
    readonly property string home: Quickshell.env("HOME")
    readonly property string soundDir: home + "/.local/share/sounds/macshell"
    readonly property color orange: "#FF9F0A"

    // ═════════════ STATE (saved) ═════════════
    property var alarms: []        // { id, h, m, label, on, days: [0..6] (0 = Sunday; empty = once) }
    property var cities: [ { name: "Cupertino", tz: "America/Los_Angeles" }, { name: "New York", tz: "America/New_York" },
                           { name: "London", tz: "Europe/London" }, { name: "Tokyo", tz: "Asia/Tokyo" } ]
    property var timer: ({ state: "idle", total: 300000, endAt: 0, left: 300000, label: "" })   // idle | running | paused
    property var sw: ({ running: false, startAt: 0, acc: 0, laps: [] })
    property var recents: []       // recent timer durations (ms), newest first
    property var timerPresets: ({}) // sound settings for recent durations
    property var snoozes: []       // { at, label }
    property var ringing: null     // { kind: "alarm" | "timer", label, time } while it rings
    property bool loaded: false
    readonly property bool managedClock: Quickshell.env("MACSHELL_CLOCK_SERVICE") !== "0"
    property bool legacyStoreBlocked: true
    readonly property bool clockControlsReady: managedClock ? (clockBackend.ready && !clockBackend.busy) : !legacyStoreBlocked
    property bool closeSheetAfterSave: false
    property string clockMessage: ""
    property string timerSoundId: ""
    property var timerSoundOptions: null
    function soundName(sound) {
        if (!sound.id || !sound.id.startsWith("builtin-")) return sound.name || "";
        var key = ({chime: "clock.sound_chime", melody: "clock.sound_melody", gentle: "clock.sound_gentle", urgent: "clock.sound_urgent"})[sound.category];
        return (key ? Language.I18n.text(key) : sound.name) + " " + Number(sound.id.slice(-2));
    }
    function soundChoices(current) {
        var choices = [{key: "", label: Language.I18n.text("clock.sound_default")}, {key: "silence", label: Language.I18n.text("clock.sound_silence")}];
        clockBackend.controller.sounds.forEach(sound => choices.push({key: sound.id, label: root.soundName(sound)}));
        if (current && !choices.some(choice => choice.key === current)) {
            choices.push({key: current, label: Language.I18n.text(current.startsWith("builtin-") && !clockBackend.controller.showBuiltins ? "clock.sound_hidden" : "clock.sound_missing")});
        }
        return choices;
    }

    ClockBackend {
        id: clockBackend
        enabled: root.managedClock
        storePath: (Quickshell.env("MACSHELL_SETTINGS_HOME") || Quickshell.env("XDG_CONFIG_HOME") || root.home + "/.config") + "/macshell/clock.json"
        soundDirectory: root.soundDir
        onSnapshotChanged: {
            if (!root.managedClock || !snapshot) return;
            function copy(value) { return JSON.parse(JSON.stringify(value)); }
            var state = snapshot, firstSnapshot = !root.loaded;
            if (!root.loaded && state.timing && state.timing.timer) {
                root.timerSoundId = state.timing.timer.soundId || "";
                root.timerSoundOptions = state.timing.timer.soundOptions || null;
            }
            var oldCities = JSON.stringify(root.cities);
            root.alarms = copy(state.alarms || []); root.cities = copy(state.cities || []); root.timer = copy(state.timer);
            root.sw = copy(state.sw); root.recents = copy(state.recents || []); root.timerPresets = copy(state.timerPresets || {}); root.ringing = state.ringing ? copy(state.ringing) : null;
            root.loaded = true;
            if (firstSnapshot || oldCities !== JSON.stringify(root.cities)) root.refreshTz();
        }
        onReadyChanged: if (ready) controller.refreshSounds()
        onCompleted: (action, success, result, error) => {
            root.clockMessage = success ? "" : Language.I18n.text("clock.operation_failed");
            if (action === "patch-settings" && root.closeSheetAfterSave) {
                if (success) win.sheet = "";
                root.closeSheetAfterSave = false;
            }
        }
    }
    ClockSoundImport {
        id: soundImporter
        directory: root.soundDir + "/library"
        onFinished: clockBackend.controller.refreshSounds()
    }
    Connections {
        target: clockBackend.controller
        function onSoundDeleted(soundId) { if (root.timerSoundId === soundId) root.timerSoundId = ""; }
    }

    property real nowMs: Date.now()
    readonly property bool timerActive: timer.state !== "idle"
    readonly property bool swActive: sw.running || sw.acc > 0

    function uid() { return Date.now().toString(36) + Math.floor(Math.random() * 1e6).toString(36); }
    function pad(n) { return (n < 10 ? "0" : "") + n; }
    function fmtHM(h, m) {
        if (use24h) return pad(h) + ":" + pad(m);
        var hh = h % 12; if (hh === 0) hh = 12;
        return hh + ":" + pad(m);
    }
    function ampm(h) { return use24h ? "" : (h < 12 ? "AM" : "PM"); }
    function timerLeft() {
        if (managedClock) return clockBackend.timerRemaining;
        if (timer.state === "running") return Math.max(0, timer.endAt - nowMs);
        return timer.left;
    }
    function fmtDur(ms, tenths) {
        var s = Math.ceil(ms / 1000);
        if (tenths) s = Math.floor(ms / 1000);
        var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), x = s % 60;
        return (h > 0 ? h + ":" + pad(m) : pad(m)) + ":" + pad(x);
    }
    function swElapsed() { return managedClock ? clockBackend.stopwatchElapsed : sw.acc + (sw.running ? nowMs - sw.startAt : 0); }
    function fmtSw(ms) {
        var cs = Math.floor(ms / 10) % 100, s = Math.floor(ms / 1000), m = Math.floor(s / 60) % 60, h = Math.floor(s / 3600);
        return (h > 0 ? h + ":" : "") + pad(m) + ":" + pad(s % 60) + "," + pad(cs);
    }
    function repeatText(days) {
        if (!days || days.length === 0) return "";
        var d = days.slice().sort();
        if (d.length === 7) return Language.I18n.text("ui.t_ed28f6cae0fa");
        if (d.join() === "1,2,3,4,5") return Language.I18n.text("clock.weekdays");
        if (d.join() === "0,6") return Language.I18n.text("clock.weekends");
        var n = Array.from({length: 7}, (_, index) => Language.I18n.formatLocale.dayName(index, Locale.ShortFormat));
        return d.map(function (i) { return n[i]; }).join(", ");
    }

    // ── persistence ──
    FileView {
        id: store
        path: (Quickshell.env("MACSHELL_SETTINGS_HOME") || Quickshell.env("XDG_CONFIG_HOME") || root.home + "/.config") + "/macshell/clock.json"
        printErrors: false
        onLoaded: {
            if (root.managedClock) return;
            try {
                var o = JSON.parse(text());
                if (!o || typeof o !== "object" || Array.isArray(o) || (o.version !== undefined && o.version !== 0)) {
                    root.legacyStoreBlocked = true; root.loaded = true; return;
                }
                root.legacyStoreBlocked = false;
                if (o.alarms) root.alarms = o.alarms;
                if (o.cities) root.cities = o.cities;
                if (o.timer) root.timer = o.timer;
                if (o.sw) root.sw = o.sw;
                if (o.recents) root.recents = o.recents;
                if (o.snoozes) root.snoozes = o.snoozes;
            } catch (e) { root.legacyStoreBlocked = true; }
            root.loaded = true;
            root.refreshTz();
        }
        onLoadFailed: { if (!root.managedClock) { root.legacyStoreBlocked = false; root.loaded = true; root.refreshTz(); } }
    }
    FileView {
        path: (Quickshell.env("MACSHELL_SETTINGS_HOME") || Quickshell.env("XDG_CONFIG_HOME") || root.home + "/.config") + "/macshell/components.json"
        printErrors: false
        onLoaded: { try { var o = JSON.parse(text()); if (o.clockEnabled !== undefined) root.appEnabled = !!o.clockEnabled; } catch (e) {} }
    }
    Timer { id: saveLater; interval: 150; onTriggered: root.saveNow() }
    function save() { if (!managedClock && !legacyStoreBlocked && loaded) saveLater.restart(); }
    function saveNow() {
        if (managedClock || legacyStoreBlocked) return;
        Quickshell.execDetached(["sh", "-c", "mkdir -p \"${MACSHELL_SETTINGS_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}}/macshell\" && printf '%s\\n' \"$1\" > \"${MACSHELL_SETTINGS_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}}/macshell/clock.json.tmp\" && mv -f \"${MACSHELL_SETTINGS_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}}/macshell/clock.json.tmp\" \"${MACSHELL_SETTINGS_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}}/macshell/clock.json\"",
            "sh", JSON.stringify({ alarms: alarms, cities: cities, timer: timer, sw: sw, recents: recents, snoozes: snoozes, ringing: ringing }, null, 1)]);
    }

    // ── alarms ──
    function addAlarm(h, m, label, days, soundId, soundOptions) {
        if (!clockControlsReady) return false;
        var a = alarms.slice(); var entry = { id: uid(), h: h, m: m, label: label || "", on: true, days: days || [], soundId: soundId || "" };
        if (soundOptions) entry.soundOptions = soundOptions;
        a.push(entry);
        a.sort(function (x, y) { return x.h * 60 + x.m - (y.h * 60 + y.m); });
        if (managedClock) return clockBackend.patchSettings({alarms: a});
        alarms = a; save();
        return true;
    }
    function updateAlarm(id, h, m, label, days, soundId, soundOptions) {
        if (!clockControlsReady) return false;
        var a = alarms.map(function (x) {
            if (x.id !== id) return x;
            var next = Object.assign({}, x, { id: id, h: h, m: m, label: label || "", on: true, days: days || [], soundId: soundId === undefined ? (x.soundId || "") : soundId });
            if (soundOptions !== undefined && soundOptions !== null) next.soundOptions = soundOptions;
            return next;
        });
        a.sort(function (x, y) { return x.h * 60 + x.m - (y.h * 60 + y.m); });
        if (managedClock) return clockBackend.patchSettings({alarms: a});
        alarms = a; save();
        return true;
    }
    function setAlarmOn(id, on) { if (!clockControlsReady) return false; var next = alarms.map(function (x) { if (x.id !== id) return x; var c = Object.assign({}, x); c.on = on; return c; }); if (managedClock) return clockBackend.patchSettings({alarms: next}); alarms = next; save(); return true; }
    function deleteAlarm(id) { if (!clockControlsReady) return false; var next = alarms.filter(function (x) { return x.id !== id; }); if (managedClock) return clockBackend.patchSettings({alarms: next}); alarms = next; save(); return true; }
    function nextAlarmText(a) {
        // "in 7 hr 12 min" style hint for the widget
        var d = new Date(nowMs), best = -1;
        for (var k = 0; k < 8; k++) {
            var t = new Date(d.getFullYear(), d.getMonth(), d.getDate() + k, a.h, a.m, 0);
            if (t.getTime() <= nowMs) continue;
            if (a.days.length === 0 || a.days.indexOf(t.getDay()) >= 0) { best = t.getTime(); break; }
        }
        return best;
    }

    // ── timer ──
    function startTimer(ms, label, soundId, soundOptions) {
        if (!clockControlsReady) return false;
        if (ms <= 0) return;
        if (managedClock) return clockBackend.startTimer(ms, label, false, soundId === undefined ? root.timerSoundId : soundId,
                                                         soundOptions === undefined ? root.timerSoundOptions : soundOptions);
        timer = { state: "running", total: ms, endAt: Date.now() + ms, left: ms, label: label || "" };
        var r = recents.filter(function (x) { return x !== ms; }); r.unshift(ms); recents = r.slice(0, 6);
        save();
    }
    function startRecent(ms) {
        var preset = timerPresets[String(ms)];
        if (!managedClock || !preset) return startTimer(ms, "");
        var accepted = startTimer(ms, "", preset.soundId || "", preset.soundOptions || null);
        if (accepted) { timerSoundId = preset.soundId || ""; timerSoundOptions = preset.soundOptions || null; }
        return accepted;
    }
    function pauseTimer() { if (!clockControlsReady) return false; if (managedClock) return clockBackend.timerAction("pause"); if (timer.state !== "running") return; var t = Object.assign({}, timer); t.left = Math.max(0, t.endAt - Date.now()); t.state = "paused"; timer = t; save(); }
    function resumeTimer() { if (!clockControlsReady) return false; if (managedClock) return clockBackend.timerAction("resume"); if (timer.state !== "paused") return; var t = Object.assign({}, timer); t.endAt = Date.now() + t.left; t.state = "running"; timer = t; save(); }
    function cancelTimer() { if (!clockControlsReady) return false; if (managedClock) return clockBackend.timerAction("cancel"); var t = Object.assign({}, timer); t.state = "idle"; t.left = t.total; timer = t; save(); }

    // ── stopwatch ──
    function swStart() { if (!clockControlsReady) return false; if (managedClock) return clockBackend.stopwatchAction("start"); sw = { running: true, startAt: Date.now(), acc: sw.acc, laps: sw.laps }; save(); }
    function swStop() { if (!clockControlsReady) return false; if (managedClock) return clockBackend.stopwatchAction("pause"); sw = { running: false, startAt: 0, acc: sw.acc + Date.now() - sw.startAt, laps: sw.laps }; save(); }
    function swLap() { if (!clockControlsReady) return false; if (managedClock) return clockBackend.stopwatchAction("lap"); var l = sw.laps.slice(); l.unshift(swElapsed()); sw = { running: sw.running, startAt: sw.startAt, acc: sw.acc, laps: l }; save(); }
    function swReset() { if (!clockControlsReady) return false; if (managedClock) return clockBackend.stopwatchAction("reset"); sw = { running: false, startAt: 0, acc: 0, laps: [] }; save(); }

    // ── world clock: UTC offsets come from the system tz database (DST-correct), refreshed hourly ──
    property var tzOff: ({})
    readonly property int localOff: -new Date(nowMs).getTimezoneOffset()
    function refreshTz() {
        var z = cities.map(function (c) { return c.tz; });
        if (z.length === 0 || tzProc.running) return;
        tzProc.command = ["sh", "-c", "for z in \"$@\"; do printf '%s %s\\n' \"$z\" \"$(TZ=$z date +%z)\"; done", "sh"].concat(z);
        tzProc.running = true;
    }
    Process {
        id: tzProc
        stdout: StdioCollector {
            onStreamFinished: {
                var o = {}, ls = text.trim().split("\n");
                for (var i = 0; i < ls.length; i++) {
                    var p = ls[i].split(" "); if (p.length < 2) continue;
                    var s = p[1], sg = s[0] === "-" ? -1 : 1;
                    o[p[0]] = sg * (parseInt(s.substr(1, 2), 10) * 60 + parseInt(s.substr(3, 2), 10));
                }
                root.tzOff = o;
            }
        }
    }
    Timer { interval: 3600000; repeat: true; running: true; onTriggered: root.refreshTz() }
    function cityDate(tz) {
        var off = tzOff[tz]; if (off === undefined) off = localOff;
        return new Date(nowMs + (off - localOff) * 60000);
    }
    function cityDayText(tz) {
        var off = tzOff[tz]; if (off === undefined) off = localOff;
        var c = cityDate(tz), l = new Date(nowMs);
        var dd = Math.round((new Date(c.getFullYear(), c.getMonth(), c.getDate()) - new Date(l.getFullYear(), l.getMonth(), l.getDate())) / 86400000);
        var day = Language.I18n.text(dd === 0 ? "clock.today" : dd > 0 ? "clock.tomorrow" : "clock.yesterday");
        var diff = (off - localOff) / 60, hrs = Math.abs(diff);
        var hs = Language.I18n.formatNumber(hrs, hrs % 1 === 0 ? 0 : 1) + " " + Language.I18n.text(hrs === 1 ? "clock.hour_short" : "clock.hours_short");
        return day + ", " + (diff >= 0 ? "+" : "-") + hs;
    }
    readonly property var cityChoices: [
        ["Abu Dhabi", "Asia/Dubai"], ["Al Ain", "Asia/Dubai"], ["Amsterdam", "Europe/Amsterdam"], ["Athens", "Europe/Athens"],
        ["Auckland", "Pacific/Auckland"], ["Bangkok", "Asia/Bangkok"], ["Barcelona", "Europe/Madrid"], ["Beijing", "Asia/Shanghai"],
        ["Berlin", "Europe/Berlin"], ["Buenos Aires", "America/Argentina/Buenos_Aires"], ["Cairo", "Africa/Cairo"],
        ["Cape Town", "Africa/Johannesburg"], ["Chicago", "America/Chicago"], ["Cupertino", "America/Los_Angeles"],
        ["Delhi", "Asia/Kolkata"], ["Denver", "America/Denver"], ["Doha", "Asia/Qatar"], ["Dubai", "Asia/Dubai"],
        ["Dublin", "Europe/Dublin"], ["Hong Kong", "Asia/Hong_Kong"], ["Honolulu", "Pacific/Honolulu"], ["Istanbul", "Europe/Istanbul"],
        ["Jakarta", "Asia/Jakarta"], ["Jeddah", "Asia/Riyadh"], ["Karachi", "Asia/Karachi"], ["Kuwait City", "Asia/Kuwait"],
        ["Lagos", "Africa/Lagos"], ["Lisbon", "Europe/Lisbon"], ["London", "Europe/London"], ["Los Angeles", "America/Los_Angeles"],
        ["Madrid", "Europe/Madrid"], ["Manila", "Asia/Manila"], ["Mexico City", "America/Mexico_City"], ["Moscow", "Europe/Moscow"],
        ["Mumbai", "Asia/Kolkata"], ["Nairobi", "Africa/Nairobi"], ["New York", "America/New_York"], ["Paris", "Europe/Paris"],
        ["Riyadh", "Asia/Riyadh"], ["Rome", "Europe/Rome"], ["San Francisco", "America/Los_Angeles"], ["São Paulo", "America/Sao_Paulo"],
        ["Seoul", "Asia/Seoul"], ["Singapore", "Asia/Singapore"], ["Stockholm", "Europe/Stockholm"], ["Sydney", "Australia/Sydney"],
        ["Tehran", "Asia/Tehran"], ["Tokyo", "Asia/Tokyo"], ["Toronto", "America/Toronto"], ["Vancouver", "America/Vancouver"],
        ["Vienna", "Europe/Vienna"], ["Zurich", "Europe/Zurich"]
    ]
    function addCity(name, tz) { if (!clockControlsReady) return false; var c = cities.slice(); c.push({ name: name, tz: tz }); if (managedClock) return clockBackend.patchSettings({cities: c}); cities = c; save(); refreshTz(); return true; }
    function removeCity(i) { if (!clockControlsReady) return false; var c = cities.slice(); c.splice(i, 1); if (managedClock) return clockBackend.patchSettings({cities: c}); cities = c; save(); return true; }

    // ═════════════ TICK + RINGING ═════════════
    // 1 s normally; 30 fps only while the stopwatch is on screen and running
    Timer {
        interval: (win.visible && win.tab === 2 && root.sw.running) ? 33 : 1000
        repeat: true; running: true
        onTriggered: { root.nowMs = Date.now(); root.check(); }
    }
    property string lastMinute: ""
    function check() {
        if (!loaded || managedClock || legacyStoreBlocked) return;
        var d = new Date(nowMs);
        if (timer.state === "running" && nowMs >= timer.endAt) {
            var t = Object.assign({}, timer); t.state = "idle"; t.left = t.total; timer = t;
            ring({ kind: "timer", label: t.label || "", defaultLabel: !t.label, time: fmtDur(t.total) });
            save();
        }
        if (snoozes.length > 0) {
            var keep = [];
            for (var s = 0; s < snoozes.length; s++) {
                if (snoozes[s].at <= nowMs) ring({ kind: "alarm", label: snoozes[s].label, defaultLabel: snoozes[s].defaultLabel, time: fmtHM(d.getHours(), d.getMinutes()) });
                else keep.push(snoozes[s]);
            }
            if (keep.length !== snoozes.length) { snoozes = keep; save(); }
        }
        var key = d.getFullYear() + "-" + d.getMonth() + "-" + d.getDate() + " " + d.getHours() + ":" + d.getMinutes();
        if (key === lastMinute) return;
        lastMinute = key;
        var changed = false, a = alarms.slice();
        for (var i = 0; i < a.length; i++) {
            var al = a[i];
            if (!al.on || al.h !== d.getHours() || al.m !== d.getMinutes()) continue;
            if (al.days.length > 0 && al.days.indexOf(d.getDay()) < 0) continue;
            ring({ kind: "alarm", label: al.label || "", defaultLabel: !al.label, time: fmtHM(al.h, al.m) + (ampm(al.h) ? " " + ampm(al.h) : "") });
            if (al.days.length === 0) { var c = Object.assign({}, al); c.on = false; a[i] = c; changed = true; }
        }
        if (changed) { alarms = a; save(); }
    }
    function ring(r) {
        ringing = r;
        ringProc.command = ["sh", "-c", "trap 'kill 0' TERM INT; while :; do pw-play --volume=0.9 \"$1\" & wait $!; sleep 0.25; done",
                            "sh", soundDir + "/" + (r.kind === "timer" ? "timer" : "alarm") + ".wav"];
        ringProc.running = false; ringProc.running = true;
        ringLimit.restart();
        save();
    }
    function stopRing() {
        if (managedClock) return clockBackend.eventAction("dismiss-event");
        if (!ringing) return;
        ringing = null; ringProc.running = false; ringLimit.stop(); save();
    }
    function snooze() {
        if (managedClock) return clockBackend.eventAction("snooze");
        if (!ringing) return;
        var s = snoozes.slice(); s.push({ at: Date.now() + 9 * 60000, label: ringing.label, defaultLabel: ringing.defaultLabel }); snoozes = s;
        stopRing();
    }
    function repeatTimer() { if (managedClock) return clockBackend.repeatTimer(); var ms = timer.total; stopRing(); startTimer(ms, timer.label); }
    function defaultRingLabel(r) {
        return !r.label || r.defaultLabel === true || (r.defaultLabel === undefined && r.label === (r.kind === "timer" ? "Timer" : "Alarm"));
    }
    Process { id: ringProc }
    Timer { id: ringLimit; interval: 5 * 60000; onTriggered: root.stopRing() }

    function open(tabName) {
        if (!appEnabled) return;
        if (tabName !== undefined) {
            var i = ["world", "alarms", "stopwatch", "timers"].indexOf(tabName);
            if (i >= 0) win.tab = i;
        }
        win.visible = true; win.raise(); win.requestActivate();
    }

    // ═════════════ RINGING BANNER (top-right, every screen's focused one) ═════════════
    PanelWindow {
        id: banner
        screen: {
            var n = Niri.focusedMonitor ? Niri.focusedMonitor.name : "";
            for (var i = 0; i < Quickshell.screens.length; i++) if (Quickshell.screens[i].name === n) return Quickshell.screens[i];
            return Quickshell.screens[0];
        }
        visible: root.appEnabled && (root.ringing !== null || bannerCard.opacity > 0.01)
        anchors { top: true; right: true }
        margins { top: 38; right: 12 }
        implicitWidth: 372; implicitHeight: 96
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "macshell-clock-alert"
        Rectangle {
            id: bannerCard
            width: 356; height: 80; x: 8; y: 4
            radius: 20
            readonly property bool on: root.ringing !== null
            opacity: on ? 1 : 0
            transform: Translate { x: bannerCard.on ? 0 : 60; Behavior on x { NumberAnimation { duration: 520; easing.type: Easing.OutQuint } } }
            Behavior on opacity { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
            color: root.darkMode ? Qt.rgba(0.17, 0.17, 0.18, 0.92) : Qt.rgba(0.97, 0.97, 0.98, 0.94)
            border.width: 1; border.color: root.darkMode ? Qt.rgba(1, 1, 1, 0.14) : Qt.rgba(0, 0, 0, 0.10)
            layer.enabled: true
            layer.effect: MultiEffect { shadowEnabled: true; shadowBlur: 0.8; shadowOpacity: 0.35; shadowVerticalOffset: 6 }
            readonly property color fg: root.darkMode ? "white" : "#1D1D1F"
            readonly property color fg2: root.darkMode ? Qt.rgba(1, 1, 1, 0.6) : Qt.rgba(0, 0, 0, 0.55)
            ClockFace { x: 14; anchors.verticalCenter: parent.verticalCenter; width: 40; height: 40; night: true; date: new Date(root.nowMs); seconds: false }
            Column {
                x: 66; anchors.verticalCenter: parent.verticalCenter
                width: parent.width - 66 - btns.width - 16
                spacing: 1
                Text { text: root.ringing ? (root.ringing.kind === "timer" ? Language.I18n.text("ui.t_cdeec2b374c1") : Language.I18n.text("ui.t_f3b679573579")) : ""; color: bannerCard.fg; font.family: root.fam; font.pixelSize: 14; font.weight: Font.DemiBold }
                Text { objectName: "clockRingMessage"; width: parent.width; elide: Text.ElideRight; text: root.ringing ? (root.ringing.kind === "timer" ? (root.defaultRingLabel(root.ringing) ? Language.I18n.text("common.done") : root.ringing.label) : ClockDisplay.ringTime(root.ringing, root.use24h) + (root.defaultRingLabel(root.ringing) ? "" : " · " + root.ringing.label)) : ""; color: bannerCard.fg2; font.family: root.fam; font.pixelSize: 13 }
            }
            Column {
                id: btns
                anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter
                spacing: 6
                Repeater {
                    model: root.ringing ? (root.ringing.kind === "timer" ? ["repeat", "stop"] : ["snooze", "stop"]) : []
                    delegate: Rectangle {
                        required property string modelData
                        objectName: "clockRingAction_" + modelData
                        width: 78; height: 28; radius: 14
                        color: modelData === "stop" ? root.orange : (bma.pressed ? Qt.rgba(0.5, 0.5, 0.5, 0.45) : Qt.rgba(0.5, 0.5, 0.5, 0.28))
                        Text { anchors.centerIn: parent; text: Language.I18n.legacy(({stop: "Stop", snooze: "Snooze", repeat: "Repeat"})[parent.modelData]); color: parent.modelData === "stop" ? "black" : bannerCard.fg; font.family: root.fam; font.pixelSize: 13; font.weight: Font.DemiBold }
                        MouseArea {
                            id: bma; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            enabled: root.clockControlsReady
                            onClicked: {
                                if (parent.modelData === "stop") root.stopRing();
                                else if (parent.modelData === "snooze") root.snooze();
                                else root.repeatTimer();
                            }
                        }
                    }
                }
            }
        }
    }

    // ═════════════ THE WINDOW ═════════════
    Window {
        id: win
        title: "Clock"
        width: 780; height: 540
        minimumWidth: 640; minimumHeight: 460
        visible: false
        color: "transparent"
        flags: Qt.Window | Qt.FramelessWindowHint
        property int tab: 1
        property string sheet: ""          // "" | "alarm" | "city"
        property var editing: null         // alarm being edited
        onTabChanged: clockBackend.controller.stopPreview()
        onSheetChanged: if (sheet !== "sounds") clockBackend.controller.stopPreview()
        onVisibleChanged: if (!visible) { sheet = ""; clockBackend.controller.stopPreview(); }

        QtObject {
            id: pal
            readonly property bool dark: root.darkMode
            readonly property color bg: dark ? "#1C1C1E" : "#F2F2F7"
            readonly property color bar: dark ? "#303033" : "#E9E9EC"
            readonly property color card: dark ? "#2C2C2E" : "#FFFFFF"
            readonly property color text: dark ? "#F5F5F7" : "#1D1D1F"
            readonly property color text2: dark ? Qt.rgba(1, 1, 1, 0.55) : Qt.rgba(0, 0, 0, 0.5)
            readonly property color text3: dark ? Qt.rgba(1, 1, 1, 0.3) : Qt.rgba(0, 0, 0, 0.28)
            readonly property color sep: dark ? Qt.rgba(1, 1, 1, 0.09) : Qt.rgba(0, 0, 0, 0.09)
            readonly property color ctrl: dark ? Qt.rgba(1, 1, 1, 0.10) : Qt.rgba(0, 0, 0, 0.06)
            readonly property color ctrlSel: dark ? "#636366" : "#FFFFFF"
            readonly property color border: dark ? Qt.rgba(1, 1, 1, 0.16) : Qt.rgba(0, 0, 0, 0.2)
            readonly property color lightOff: dark ? Qt.rgba(1, 1, 1, 0.2) : Qt.rgba(0, 0, 0, 0.15)
        }

        Rectangle {
            id: frame
            anchors.fill: parent
            radius: 12
            color: pal.bg
            border.width: 1; border.color: pal.border
            clip: true

            // resize edges
            MouseArea { x: parent.width - 8; y: parent.height - 8; width: 8; height: 8; z: 100; cursorShape: Qt.SizeFDiagCursor; onPressed: win.startSystemResize(Qt.BottomEdge | Qt.RightEdge) }
            MouseArea { x: parent.width - 5; y: 10; width: 5; height: parent.height - 20; z: 100; cursorShape: Qt.SizeHorCursor; onPressed: win.startSystemResize(Qt.RightEdge) }
            MouseArea { x: 10; y: parent.height - 5; width: parent.width - 20; height: 5; z: 100; cursorShape: Qt.SizeVerCursor; onPressed: win.startSystemResize(Qt.BottomEdge) }

            // ── toolbar ──
            Rectangle {
                id: toolbar
                width: parent.width; height: 52
                color: pal.bar
                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: pal.sep }
                DragHandler { target: null; onActiveChanged: if (active) win.startSystemMove() }
                // traffic lights
                Item {
                    x: 17; anchors.verticalCenter: parent.verticalCenter
                    width: 58; height: 14
                    Row {
                        spacing: 8
                        Repeater {
                            model: [{ c: "#FF5F57", g: "×" }, { c: "#FEBC2E", g: "−" }, { c: "#28C840", g: "↗" }]
                            delegate: Rectangle {
                                required property var modelData
                                width: 14; height: 14; radius: 7
                                color: (win.active || tlMa.containsMouse) ? modelData.c : pal.lightOff
                                border.width: 1; border.color: Qt.rgba(0, 0, 0, 0.14)
                                Text { anchors.centerIn: parent; visible: tlMa.containsMouse; text: parent.modelData.g; font.pixelSize: 11; font.bold: true; color: Qt.rgba(0, 0, 0, 0.55) }
                            }
                        }
                    }
                    MouseArea {
                        id: tlMa; anchors.fill: parent; hoverEnabled: true
                        onClicked: mouse => {
                            if (mouse.x < 22) win.visible = false;
                            else if (mouse.x < 44) win.showMinimized();
                            else win.visibility === Window.FullScreen ? win.showNormal() : win.showFullScreen();
                        }
                    }
                }
                // tabs (segmented control)
                Rectangle {
                    id: seg
                    anchors.centerIn: parent
                    width: segRow.width + 4; height: 26; radius: 7
                    color: pal.ctrl
                    Rectangle {
                        y: 2; height: parent.height - 4; radius: 6
                        readonly property Item cur: segRep.count > win.tab ? segRep.itemAt(win.tab) : null
                        x: 2 + (cur ? cur.x : 0)
                        width: cur ? cur.width : 0
                        color: pal.ctrlSel
                        layer.enabled: true
                        layer.effect: MultiEffect { shadowEnabled: true; shadowBlur: 0.3; shadowOpacity: 0.25; shadowVerticalOffset: 1 }
                        Behavior on x { NumberAnimation { duration: 320; easing.type: Easing.OutQuint } }
                        Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutQuint } }
                    }
                    Row {
                        id: segRow
                        x: 2; anchors.verticalCenter: parent.verticalCenter
                        Repeater {
                            id: segRep
                            model: [Language.I18n.text("ui.t_9d55c499e694"), Language.I18n.text("ui.t_f700e2fb4728"), Language.I18n.text("ui.t_cb880222ede3"), Language.I18n.text("ui.t_cca94c56deb8")]
                            delegate: Item {
                                required property string modelData
                                required property int index
                                width: tl.implicitWidth + 28; height: 22
                                Text { id: tl; anchors.centerIn: parent; text: parent.modelData; color: pal.text; font.family: root.fam; font.pixelSize: 13; font.weight: win.tab === parent.index ? Font.DemiBold : Font.Normal }
                                MouseArea { anchors.fill: parent; onClicked: win.tab = parent.index }
                            }
                        }
                    }
                }
                // + (add)
                ControlButton {
                    objectName: "clockSoundsOpen"; anchors.right: parent.right; anchors.rightMargin: 51; anchors.verticalCenter: parent.verticalCenter
                    width: 34; implicitWidth: 34; implicitHeight: 28; text: "♫"
                    font.pixelSize: 16; palette.button: pal.ctrl; palette.buttonText: pal.text
                    Accessible.name: Language.I18n.text("clock.sound_library")
                    visible: root.managedClock; enabled: clockBackend.ready
                    onClicked: win.sheet = "sounds"
                }
                Rectangle {
                    anchors.right: parent.right; anchors.rightMargin: 14; anchors.verticalCenter: parent.verticalCenter
                    width: 30; height: 26; radius: 7
                    visible: win.tab === 0 || win.tab === 1
                    color: addMa.pressed ? pal.ctrl : (addMa.containsMouse ? Qt.rgba(0.5, 0.5, 0.5, 0.15) : "transparent")
                    Text { anchors.centerIn: parent; anchors.verticalCenterOffset: -1; text: "+"; color: pal.text; font.pixelSize: 22; font.weight: Font.Light }
                    MouseArea {
                        id: addMa; anchors.fill: parent; hoverEnabled: true
                        enabled: root.clockControlsReady
                        onClicked: { if (win.tab === 0) win.sheet = "city"; else { win.editing = null; win.sheet = "alarm"; } }
                    }
                }
            }

            // ── pages ──
            Item {
                id: pages
                anchors.top: toolbar.bottom; anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                Repeater {
                    model: [pWorld, pAlarms, pStopwatch, pTimers]
                    delegate: Loader {
                        required property var modelData
                        required property int index
                        anchors.fill: parent
                        sourceComponent: modelData
                        active: win.visible && (win.tab === index || opacity > 0)
                        opacity: win.tab === index ? 1 : 0
                        scale: win.tab === index ? 1 : 0.985
                        visible: opacity > 0
                        Behavior on opacity { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
                        Behavior on scale { NumberAnimation { duration: 420; easing.type: Easing.OutQuint } }
                    }
                }
            }

            Rectangle {
                anchors.fill: pages; z: 90
                visible: root.managedClock && snoozeRecovery.entries.length > 0
                color: pal.bg
                Flickable {
                    anchors.fill: parent; anchors.margins: 24; clip: true
                    contentWidth: width; contentHeight: snoozeRecovery.implicitHeight
                    ClockSnoozeRecovery { id: snoozeRecovery; width: parent.width; clock: clockBackend.controller; darkMode: root.darkMode }
                }
            }
            Rectangle {
                anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                height: statusText.implicitHeight + 12; z: 110
                visible: root.managedClock && (!clockBackend.ready || root.clockMessage !== "" || clockBackend.error !== "")
                color: pal.card
                Text {
                    id: statusText; anchors.centerIn: parent; width: parent.width - 24
                    text: !clockBackend.ready ? Language.I18n.text("clock.service_unavailable") : (root.clockMessage ||
                        Language.I18n.text(clockBackend.error === "Clock sound failed; using the built-in sound" ? "clock.sound_fallback" : "clock.service_error"))
                    color: pal.text2; font.family: root.fam; font.pixelSize: 12; elide: Text.ElideRight
                }
            }

            // ── sheets ──
            Rectangle {
                anchors.fill: parent
                color: Qt.rgba(0, 0, 0, 0.35)
                opacity: win.sheet !== "" ? 1 : 0
                visible: opacity > 0
                Behavior on opacity { NumberAnimation { duration: 220 } }
                MouseArea { anchors.fill: parent; onClicked: win.sheet = "" }
            }
            Loader {
                anchors.horizontalCenter: parent.horizontalCenter
                y: win.sheet === "alarm" ? 45 : win.sheet !== "" ? 70 : 40
                Behavior on y { NumberAnimation { duration: 420; easing.type: Easing.OutQuint } }
                opacity: win.sheet !== "" ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 220 } }
                visible: opacity > 0
                active: win.sheet !== "" || opacity > 0
                sourceComponent: win.sheet === "city" ? sCity : win.sheet === "sounds" ? sSounds : sAlarm
            }
        }

        // ═════ World Clock ═════
        Component {
            id: pWorld
            Flickable {
                contentHeight: grid.height + 48
                clip: true
                Flow {
                    id: grid
                    x: 24; y: 24
                    width: parent.width - 48
                    spacing: 18
                    Repeater {
                        model: root.cities
                        delegate: Item {
                            id: cc
                            required property var modelData
                            required property int index
                            readonly property var d: root.cityDate(modelData.tz)
                            width: 160; height: 224
                            Rectangle {
                                anchors.fill: parent; radius: 16
                                color: pal.dark ? "#28282b" : "#ffffff"
                                border.width: 1; border.color: pal.sep
                            }
                            ClockFace {
                                anchors.horizontalCenter: parent.horizontalCenter
                                y: 10; width: 136; height: 136
                                date: cc.d
                                night: cc.d.getHours() < 6 || cc.d.getHours() >= 18
                            }
                            Column {
                                y: 158; width: parent.width
                                spacing: 2
                                Text { anchors.horizontalCenter: parent.horizontalCenter; text: Language.I18n.cityName(cc.modelData.tz, cc.modelData.name); color: pal.text; font.family: root.fam; font.pixelSize: 15; font.weight: Font.DemiBold }
                                Text { anchors.horizontalCenter: parent.horizontalCenter; text: root.cityDayText(cc.modelData.tz); color: pal.text2; font.family: root.fam; font.pixelSize: 11 }
                                Text { anchors.horizontalCenter: parent.horizontalCenter; text: root.fmtHM(cc.d.getHours(), cc.d.getMinutes()) + (root.use24h ? "" : " " + root.ampm(cc.d.getHours())); color: pal.text2; font.family: root.fam; font.pixelSize: 13 }
                            }
                            // remove (hover)
                            Rectangle {
                                x: 6; y: 2; width: 22; height: 22; radius: 11
                                color: "#FF453A"
                                opacity: cma.containsMouse ? 1 : 0
                                Behavior on opacity { NumberAnimation { duration: 160 } }
                                Text { anchors.centerIn: parent; anchors.verticalCenterOffset: -1; text: "−"; color: "white"; font.pixelSize: 16; font.bold: true }
                                MouseArea { anchors.fill: parent; enabled: parent.opacity > 0.5 && root.clockControlsReady; onClicked: root.removeCity(cc.index) }
                            }
                            MouseArea { id: cma; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                        }
                    }
                }
                Text {
                    visible: root.cities.length === 0
                    anchors.centerIn: parent
                    text: Language.I18n.text("ui.t_0ad45dc92910"); color: pal.text3; font.family: root.fam; font.pixelSize: 22
                }
            }
        }

        // ═════ Alarms ═════
        Component {
            id: pAlarms
            Item {
            id: alPage
            Flickable {
                anchors.fill: parent
                contentHeight: alCol.height + 24
                clip: true
                Column {
                    id: alCol
                    x: 24; y: 12
                    width: parent.width - 48
                    ClockMissedEvents { width: parent.width; backend: clockBackend; darkMode: root.darkMode; visible: root.managedClock && entries.length > 0 }
                    Repeater {
                        model: root.alarms
                        delegate: Item {
                            id: ar
                            required property var modelData
                            required property int index
                            width: alCol.width; height: 92
                            Rectangle { anchors.fill: parent; anchors.topMargin: 2; anchors.bottomMargin: 2; radius: 10; color: rowMa.containsMouse ? Qt.rgba(0.5, 0.5, 0.5, 0.08) : "transparent" }
                            Rectangle { anchors.bottom: parent.bottom; x: 12; width: parent.width - 24; height: 1; color: pal.sep; visible: ar.index < root.alarms.length - 1 }
                            MouseArea { id: rowMa; anchors.fill: parent; hoverEnabled: true; enabled: root.clockControlsReady; onClicked: { win.editing = ar.modelData; win.sheet = "alarm"; } }
                            Row {
                                x: 12; y: 10
                                spacing: 4
                                Text {
                                    text: root.fmtHM(ar.modelData.h, ar.modelData.m)
                                    color: ar.modelData.on ? pal.text : pal.text3
                                    font.family: root.fam; font.pixelSize: 50; font.weight: Font.Light
                                    Behavior on color { ColorAnimation { duration: 220 } }
                                }
                                Text {
                                    anchors.baseline: parent.children[0].baseline
                                    text: root.ampm(ar.modelData.h)
                                    color: ar.modelData.on ? pal.text : pal.text3
                                    font.family: root.fam; font.pixelSize: 26; font.weight: Font.Light
                                }
                            }
                            Text {
                                x: 13; y: 66
                                text: (ar.modelData.label || Language.I18n.text("ui.t_f3b679573579")) + (ar.modelData.days.length ? ", " + root.repeatText(ar.modelData.days) : "")
                                color: ar.modelData.on ? pal.text2 : pal.text3
                                font.family: root.fam; font.pixelSize: 13
                            }
                            // delete (hover)
                            Rectangle {
                                anchors.right: sw1.left; anchors.rightMargin: 16; anchors.verticalCenter: parent.verticalCenter
                                width: 26; height: 26; radius: 13
                                color: delMa.containsMouse ? "#FF453A" : Qt.rgba(0.5, 0.5, 0.5, 0.22)
                                opacity: rowMa.containsMouse || delMa.containsMouse ? 1 : 0
                                Behavior on opacity { NumberAnimation { duration: 160 } }
                                Text { anchors.centerIn: parent; text: "✕"; color: "white"; font.pixelSize: 11; font.bold: true }
                                MouseArea { id: delMa; anchors.fill: parent; hoverEnabled: true; enabled: root.clockControlsReady; onClicked: root.deleteAlarm(ar.modelData.id) }
                            }
                            CSwitch { id: sw1; anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter; enabled: root.clockControlsReady; on: ar.modelData.on; onToggled: v => root.setAlarmOn(ar.modelData.id, v) }
                        }
                    }
                }
                Column {
                    visible: root.alarms.length === 0 && !(root.managedClock && clockBackend.timing && ((clockBackend.timing.missedAlarms && clockBackend.timing.missedAlarms.length) || (clockBackend.timing.missedSnoozes && clockBackend.timing.missedSnoozes.length)))
                    parent: alPage
                    anchors.centerIn: parent
                    spacing: 8
                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: Language.I18n.text("ui.t_bbe576ff8caf"); color: pal.text3; font.family: root.fam; font.pixelSize: 22 }
                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: Language.I18n.text("ui.t_5dbd7b01e5b5"); color: pal.text3; font.family: root.fam; font.pixelSize: 13 }
                }
            }
            }
        }

        // ═════ Stopwatch ═════
        Component {
            id: pStopwatch
            Item {
                id: stopwatchPage
                readonly property real el: root.swElapsed()
                Text {
                    id: swTxt
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: parent.height * 0.12
                    text: root.managedClock && clockBackend.stopwatchStatus === "unavailable" ? "--:--" : root.fmtSw(parent.el)
                    color: pal.text
                    font.family: root.fam; font.pixelSize: Math.min(96, parent.width / 6.2); font.weight: Font.Light
                    font.features: { "tnum": 1 }
                }
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: swTxt.y + swTxt.height + 26
                    spacing: parent.width * 0.32
                    RoundBtn {
                        label: root.sw.running ? Language.I18n.text("ui.t_a2baa08ca9b1") : Language.I18n.text("ui.t_daee7606b339")
                        enabledBtn: root.clockControlsReady && (root.sw.running || root.sw.acc > 0)
                        fill: Qt.rgba(0.5, 0.5, 0.5, 0.25); ink: pal.text
                        onClicked: root.sw.running ? root.swLap() : root.swReset()
                    }
                    RoundBtn {
                        enabledBtn: root.clockControlsReady
                        label: root.sw.running ? Language.I18n.text("ui.t_cae7d57bc067") : Language.I18n.text("ui.t_e4bb9f1ece9a")
                        fill: root.sw.running ? Qt.rgba(1, 0.27, 0.23, 0.28) : Qt.rgba(0.19, 0.82, 0.35, 0.28)
                        ink: root.sw.running ? "#FF453A" : "#30D158"
                        onClicked: root.sw.running ? root.swStop() : root.swStart()
                    }
                }
                ListView {
                    id: laps
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: swTxt.y + swTxt.height + 130
                    width: Math.min(460, parent.width - 48); height: parent.height - y - 12
                    clip: true
                    model: root.sw.laps.length + (root.swActive ? 1 : 0)
                    readonly property var lapTimes: {
                        // per-lap durations, newest first; index 0 = the lap in progress
                        var L = root.sw.laps, out = [];
                        var cur = parent.el - (L.length ? L[0] : 0);
                        if (root.swActive) out.push(cur);
                        for (var i = 0; i < L.length; i++) out.push(L[i] - (i + 1 < L.length ? L[i + 1] : 0));
                        return out;
                    }
                    readonly property real best: { var v = lapTimes.slice(root.swActive ? 1 : 0); return v.length > 1 ? Math.min.apply(null, v) : -1; }
                    readonly property real worst: { var v = lapTimes.slice(root.swActive ? 1 : 0); return v.length > 1 ? Math.max.apply(null, v) : -1; }
                    delegate: Item {
                        required property int index
                        width: laps.width; height: 40
                        readonly property real t: laps.lapTimes[index] || 0
                        readonly property color c: (index > 0 || !root.swActive) && t === laps.best ? "#30D158" : ((index > 0 || !root.swActive) && t === laps.worst ? "#FF453A" : pal.text)
                        Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: pal.sep }
                        Text { anchors.verticalCenter: parent.verticalCenter; text: Language.I18n.text("ui.t_36b2c4665913") + (laps.count - parent.index); color: parent.c; font.family: root.fam; font.pixelSize: 15 }
                        Text { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: root.fmtSw(parent.t); color: parent.c; font.family: root.fam; font.pixelSize: 15; font.features: { "tnum": 1 } }
                    }
                }
                Rectangle {
                    anchors.fill: parent; z: 5; color: pal.bg
                    visible: !!(root.managedClock && clockBackend.timing && clockBackend.timing.stopwatch && clockBackend.timing.stopwatch.state === "recovery")
                    ClockStateRecovery { anchors.centerIn: parent; width: Math.min(560, parent.width - 48); backend: clockBackend; kind: "stopwatch"; darkMode: root.darkMode }
                }
            }
        }

        // ═════ Timers ═════
        Component {
            id: pTimers
            Item {
                id: tp
                // idle: wheels + Start; running / paused: the ring
                Item {
                    anchors.fill: parent
                    opacity: root.timerActive ? 0 : 1
                    visible: opacity > 0
                    Behavior on opacity { NumberAnimation { duration: 260 } }
                    // the selection band behind the middle row, then the three wheels
                    Rectangle {
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: wheels.y + wheels.height / 2 - 18
                        width: wheels.width + 24; height: 36; radius: 8; color: pal.ctrl
                    }
                    Row {
                        id: wheels
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: 10
                        spacing: 6
                        Repeater {
                            model: [{ n: 24, u: "hours", v: Math.floor(root.timer.total / 3600000) },
                                    { n: 60, u: "min", v: Math.floor(root.timer.total / 60000) % 60 },
                                    { n: 60, u: "sec", v: Math.floor(root.timer.total / 1000) % 60 }]
                            delegate: Row {
                                required property var modelData
                                required property int index
                                spacing: 4
                                Wheel { ink: pal.text; fam: root.fam;
                                    width: 56
                                    labels: root.range(parent.modelData.n, false)
                                    start: parent.modelData.v
                                    align: Text.AlignRight
                                    onValueChanged: tp.parts[parent.index] = value
                                    Component.onCompleted: tp.parts[parent.index] = start
                                }
                                Text { anchors.verticalCenter: parent.verticalCenter; width: 46; text: Language.I18n.legacy(parent.modelData.u); color: pal.text; font.family: root.fam; font.pixelSize: 15; font.weight: Font.DemiBold }
                            }
                        }
                    }
                    Rectangle {
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: wheels.y + wheels.height + 14
                        width: 300; height: 34; radius: 8; color: pal.ctrl
                        Text { x: 12; anchors.verticalCenter: parent.verticalCenter; text: Language.I18n.text("ui.t_0e66373f45dc"); color: pal.text; font.family: root.fam; font.pixelSize: 13 }
                        TextInput {
                            id: tLabel
                            anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter
                            width: 200; horizontalAlignment: TextInput.AlignRight
                            color: pal.text2; font.family: root.fam; font.pixelSize: 13
                            text: ""
                            Text { anchors.right: parent.right; visible: parent.text === ""; text: Language.I18n.text("ui.t_cdeec2b374c1"); color: pal.text3; font: parent.font }
                        }
                    }
                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: wheels.y + wheels.height + 56; width: 300; height: 34; spacing: 6; visible: root.managedClock
                        ControlComboBox {
                            objectName: "clockTimerSound"; width: 250; height: 34
                            model: root.soundChoices(root.timerSoundId); textRole: "label"
                            currentIndex: Math.max(0, model.findIndex(item => item.key === root.timerSoundId))
                            Accessible.name: Language.I18n.text("clock.sound_choice")
                            palette.base: pal.ctrl; palette.buttonText: pal.text; palette.text: pal.text
                            palette.window: pal.card; palette.highlight: root.accent
                            onActivated: index => root.timerSoundId = model[index].key
                        }
                        ControlButton {
                            objectName: "clockTimerSoundOptions"; width: 44; implicitWidth: 44; implicitHeight: 34
                            text: "⚙"; Accessible.name: Language.I18n.text("clock.sound_options")
                            palette.button: pal.ctrl; palette.buttonText: pal.text
                            onClicked: timerSoundOptions.openFor(root.timerSoundOptions, root.timerSoundId, "timer")
                        }
                    }
                    ClockSoundOptions {
                        id: timerSoundOptions
                        client: clockBackend.controller; darkMode: root.darkMode; family: root.fam
                        onApplied: value => root.timerSoundOptions = value
                    }
                    RoundBtn {
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: wheels.y + wheels.height + (root.managedClock ? 104 : 66)
                        width: root.managedClock ? 62 : 78; height: width
                        label: Language.I18n.text("ui.t_e4bb9f1ece9a")
                        enabledBtn: root.clockControlsReady
                        fill: Qt.rgba(0.19, 0.82, 0.35, 0.28); ink: "#30D158"
                        onClicked: root.startTimer(((tp.parts[0] || 0) * 3600 + (tp.parts[1] || 0) * 60 + (tp.parts[2] || 0)) * 1000, tLabel.text)
                    }
                    // recents
                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom; anchors.bottomMargin: 18
                        spacing: 10
                        visible: root.recents.length > 0
                        Text { anchors.verticalCenter: parent.verticalCenter; text: Language.I18n.text("ui.t_41a86988751a"); color: pal.text2; font.family: root.fam; font.pixelSize: 12; font.weight: Font.DemiBold }
                        Repeater {
                            model: root.recents
                            delegate: Rectangle {
                                required property var modelData
                                width: rt.implicitWidth + 22; height: 26; radius: 13
                                color: rma.pressed ? pal.ctrlSel : pal.ctrl
                                Text { id: rt; anchors.centerIn: parent; text: root.fmtDur(parent.modelData); color: pal.text; font.family: root.fam; font.pixelSize: 12 }
                                MouseArea { id: rma; anchors.fill: parent; enabled: root.clockControlsReady; onClicked: root.startRecent(parent.modelData) }
                            }
                        }
                    }
                }
                property var parts: [0, 5, 0]

                Item {
                    anchors.fill: parent
                    opacity: root.timerActive ? 1 : 0
                    scale: root.timerActive ? 1 : 0.94
                    visible: opacity > 0
                    Behavior on opacity { NumberAnimation { duration: 300 } }
                    Behavior on scale { NumberAnimation { duration: 520; easing.type: Easing.OutQuint } }
                    readonly property real remain: root.timerLeft()
                    readonly property real frac: root.timer.total > 0 ? remain / root.timer.total : 0
                    Item {
                        id: ring
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: 22
                        width: Math.min(300, parent.height - 140); height: width
                        Ring { anchors.fill: parent; frac: 1; ink: Qt.rgba(0.5, 0.5, 0.5, 0.22); lineW: 9 }
                        Ring { anchors.fill: parent; frac: parent.parent.frac; ink: root.orange; lineW: 9; smoothFrac: root.timer.state === "running" }
                        Column {
                            anchors.centerIn: parent
                            spacing: 4
                            Text { anchors.horizontalCenter: parent.horizontalCenter; text: root.timer.label || ""; visible: text !== ""; color: pal.text2; font.family: root.fam; font.pixelSize: 15 }
                            Text { anchors.horizontalCenter: parent.horizontalCenter; text: root.managedClock && clockBackend.timerStatus === "unavailable" ? "--:--" : root.fmtDur(parent.parent.parent.remain); color: pal.text; font.family: root.fam; font.pixelSize: ring.width / 5; font.weight: Font.Light; font.features: { "tnum": 1 } }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                readonly property var end: new Date(root.nowMs + parent.parent.parent.remain)
                                text: "🔔 " + root.fmtHM(end.getHours(), end.getMinutes()) + (root.use24h ? "" : " " + root.ampm(end.getHours()))
                                color: root.timer.state === "paused" ? pal.text3 : pal.text2
                                font.family: root.fam; font.pixelSize: 14
                            }
                        }
                    }
                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: ring.y + ring.height + 22
                        spacing: Math.max(80, ring.width - 160)
                        RoundBtn { label: Language.I18n.text("common.cancel"); enabledBtn: root.clockControlsReady; fill: Qt.rgba(0.5, 0.5, 0.5, 0.25); ink: pal.text; onClicked: root.cancelTimer() }
                        RoundBtn {
                            enabledBtn: root.clockControlsReady
                            label: root.timer.state === "running" ? Language.I18n.text("ui.t_858e4ba7a29f") : Language.I18n.text("ui.t_d640c7421da0")
                            fill: root.timer.state === "running" ? Qt.rgba(1, 0.62, 0.04, 0.26) : Qt.rgba(0.19, 0.82, 0.35, 0.28)
                            ink: root.timer.state === "running" ? root.orange : "#30D158"
                            onClicked: root.timer.state === "running" ? root.pauseTimer() : root.resumeTimer()
                        }
                    }
                }
                Rectangle {
                    anchors.fill: parent; z: 5; color: pal.bg
                    visible: !!(root.managedClock && clockBackend.timing && clockBackend.timing.timer && clockBackend.timing.timer.state === "recovery")
                    ClockStateRecovery { anchors.centerIn: parent; width: Math.min(560, parent.width - 48); backend: clockBackend; kind: "timer"; darkMode: root.darkMode }
                }
            }
        }

        // ═════ sheets ═════
        Component {
            id: sSounds
            ClockSounds {
                objectName: "clockSoundsPanel"
                client: clockBackend.controller; importer: soundImporter
                darkMode: root.darkMode; family: root.fam; availableHeight: Math.max(280, win.height - 84)
                onDismissed: win.sheet = ""
            }
        }
        Component {
            id: sAlarm
            Rectangle {
                id: sa
                width: 360; height: root.managedClock ? 410 : 360; radius: 14
                color: pal.card
                border.width: 1; border.color: pal.sep
                layer.enabled: true
                layer.effect: MultiEffect { shadowEnabled: true; shadowBlur: 1.0; shadowOpacity: 0.4; shadowVerticalOffset: 10 }
                readonly property var ed: win.editing
                property var days: ed ? ed.days.slice() : []
                property string soundId: ed && ed.soundId ? ed.soundId : ""
                property var soundOptions: ed && ed.soundOptions ? ed.soundOptions : null
                property bool pm: ed ? ed.h >= 12 : false
                Text { x: 20; y: 16; text: sa.ed ? Language.I18n.text("ui.t_f2dc46a595f3") : Language.I18n.text("ui.t_547fc2ea687c"); color: pal.text; font.family: root.fam; font.pixelSize: 15; font.weight: Font.DemiBold }
                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: tw.y + tw.height / 2 - 18
                    width: tw.width + 20; height: 36; radius: 8; color: pal.ctrl
                }
                Row {
                    id: tw
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: 46
                    spacing: 2
                    Wheel { ink: pal.text; fam: root.fam;
                        id: hT
                        labels: root.use24h ? root.range(24, true) : ["12", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11"]
                        fontPx: 26
                        start: { var h = sa.ed ? sa.ed.h : new Date().getHours(); return root.use24h ? h : h % 12; }
                    }
                    Text { anchors.verticalCenter: parent.verticalCenter; text: ":"; color: pal.text; font.family: root.fam; font.pixelSize: 26 }
                    Wheel { ink: pal.text; fam: root.fam; id: mT; labels: root.range(60, true); fontPx: 26; start: sa.ed ? sa.ed.m : new Date().getMinutes() }
                    Wheel { ink: pal.text; fam: root.fam; id: pT; visible: !root.use24h; width: 56; labels: ["AM", "PM"]; fontPx: 20; start: sa.pm ? 1 : 0 }
                }
                // repeat days
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: tw.y + tw.height + 14
                    spacing: 6
                    Repeater {
                        model: Array.from({length: 7}, (_, index) => Language.I18n.formatLocale.dayName(index, Locale.ShortFormat))
                        delegate: Rectangle {
                            required property string modelData
                            required property int index
                            readonly property bool sel: sa.days.indexOf(index) >= 0
                            width: 32; height: 32; radius: 16
                            color: sel ? root.orange : pal.ctrl
                            Behavior on color { ColorAnimation { duration: 160 } }
                            Text { anchors.centerIn: parent; text: parent.modelData; color: parent.sel ? "black" : pal.text; font.family: root.fam; font.pixelSize: 13; font.weight: Font.DemiBold }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: {
                                    var d = sa.days.slice(), i = d.indexOf(parent.index);
                                    if (i >= 0) d.splice(i, 1); else d.push(parent.index);
                                    sa.days = d;
                                }
                            }
                        }
                    }
                }
                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: tw.y + tw.height + 58
                    width: 320; height: 32; radius: 8; color: pal.ctrl
                    Text { x: 12; anchors.verticalCenter: parent.verticalCenter; text: Language.I18n.text("ui.t_0e66373f45dc"); color: pal.text; font.family: root.fam; font.pixelSize: 13 }
                    TextInput {
                        id: aLabel
                        anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter
                        width: 220; horizontalAlignment: TextInput.AlignRight
                        text: sa.ed ? sa.ed.label : ""
                        color: pal.text2; font.family: root.fam; font.pixelSize: 13
                        Text { anchors.right: parent.right; visible: parent.text === ""; text: Language.I18n.text("ui.t_f3b679573579"); color: pal.text3; font: parent.font }
                    }
                }
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: tw.y + tw.height + 100; width: 320; height: 32; spacing: 6; visible: root.managedClock
                    ControlComboBox {
                        objectName: "clockAlarmSound"; width: 270; height: 32
                        model: root.soundChoices(sa.soundId); textRole: "label"
                        currentIndex: Math.max(0, model.findIndex(item => item.key === sa.soundId))
                        Accessible.name: Language.I18n.text("clock.sound_choice")
                        palette.base: pal.ctrl; palette.buttonText: pal.text; palette.text: pal.text
                        palette.window: pal.card; palette.highlight: root.accent
                        onActivated: index => sa.soundId = model[index].key
                    }
                    ControlButton {
                        objectName: "clockAlarmSoundOptions"; width: 44; implicitWidth: 44; implicitHeight: 32
                        text: "⚙"; Accessible.name: Language.I18n.text("clock.sound_options")
                        palette.button: pal.ctrl; palette.buttonText: pal.text
                        onClicked: alarmSoundOptions.openFor(sa.soundOptions, sa.soundId, "alarm")
                    }
                }
                ClockSoundOptions {
                    id: alarmSoundOptions
                    client: clockBackend.controller; darkMode: root.darkMode; family: root.fam
                    onApplied: value => sa.soundOptions = value
                }
                Row {
                    anchors.right: parent.right; anchors.rightMargin: 16
                    anchors.bottom: parent.bottom; anchors.bottomMargin: 14
                    spacing: 8
                    Repeater {
                        model: ["cancel", "save"]
                        delegate: Rectangle {
                            required property string modelData
                            objectName: "clockAlarmAction_" + modelData
                            width: 84; height: 28; radius: 7
                            color: modelData === "save" ? root.accent : pal.ctrl
                            Text { anchors.centerIn: parent; text: parent.modelData === "save" ? Language.I18n.text("ui.t_1509f561f241") : Language.I18n.text("common.cancel"); color: parent.modelData === "save" ? "white" : pal.text; font.family: root.fam; font.pixelSize: 13 }
                            MouseArea {
                                anchors.fill: parent
                                enabled: parent.modelData !== "save" || root.clockControlsReady
                                onClicked: {
                                    if (parent.modelData === "save") {
                                        var h = root.use24h ? hT.value : (hT.value + (pT.value === 1 ? 12 : 0));
                                        var accepted = sa.ed ? root.updateAlarm(sa.ed.id, h, mT.value, aLabel.text, sa.days, sa.soundId, sa.soundOptions)
                                                             : root.addAlarm(h, mT.value, aLabel.text, sa.days, sa.soundId, sa.soundOptions);
                                        if (root.managedClock) { root.closeSheetAfterSave = !!accepted; return; }
                                    }
                                    root.closeSheetAfterSave = false;
                                    win.sheet = "";
                                }
                            }
                        }
                    }
                }
            }
        }
        Component {
            id: sCity
            Rectangle {
                id: sc
                width: 360; height: 400; radius: 14
                color: pal.card
                border.width: 1; border.color: pal.sep
                layer.enabled: true
                layer.effect: MultiEffect { shadowEnabled: true; shadowBlur: 1.0; shadowOpacity: 0.4; shadowVerticalOffset: 10 }
                Rectangle {
                    x: 14; y: 14; width: parent.width - 28; height: 30; radius: 8; color: pal.ctrl
                    TextInput {
                        id: q
                        x: 10; anchors.verticalCenter: parent.verticalCenter; width: parent.width - 20
                        color: pal.text; font.family: root.fam; font.pixelSize: 13
                        focus: true
                        Component.onCompleted: forceActiveFocus()
                        Text { visible: parent.text === ""; text: Language.I18n.text("ui.t_86800df7f740"); color: pal.text3; font: parent.font }
                    }
                }
                ListView {
                    x: 6; y: 54; width: parent.width - 12; height: parent.height - 64
                    clip: true
                    model: root.cityChoices.filter(function (c) { return q.text === "" || (c[0] + " " + Language.I18n.cityName(c[1], c[0])).toLowerCase().indexOf(q.text.toLowerCase()) >= 0; })
                    delegate: Rectangle {
                        required property var modelData
                        width: ListView.view.width; height: 32; radius: 6
                        color: cma2.containsMouse ? root.accent : "transparent"
                        Text { x: 12; anchors.verticalCenter: parent.verticalCenter; text: Language.I18n.cityName(parent.modelData[1], parent.modelData[0]); color: cma2.containsMouse ? "white" : pal.text; font.family: root.fam; font.pixelSize: 13 }
                        MouseArea { id: cma2; anchors.fill: parent; hoverEnabled: true; enabled: root.clockControlsReady; onClicked: { var accepted = root.addCity(parent.modelData[0], parent.modelData[1]); if (root.managedClock) root.closeSheetAfterSave = !!accepted; else win.sheet = ""; } }
                    }
                }
            }
        }
    }

    // ═════════════ small parts ═════════════
    function range(n, padded) { var a = []; for (var i = 0; i < n; i++) a.push(padded ? pad(i) : String(i)); return a; }

    component CSwitch: Rectangle {
        id: csw
        property bool on: false
        signal toggled(bool v)
        width: 38; height: 22; radius: 11
        color: on ? "#30D158" : (root.darkMode ? Qt.rgba(1, 1, 1, 0.22) : Qt.rgba(0, 0, 0, 0.14))
        Behavior on color { ColorAnimation { duration: 200 } }
        Rectangle {
            width: 18; height: 18; radius: 9; y: 2
            x: csw.on ? csw.width - width - 2 : 2
            Behavior on x { NumberAnimation { duration: 260; easing.type: Easing.OutQuint } }
            color: "white"
            layer.enabled: true
            layer.effect: MultiEffect { shadowEnabled: true; shadowBlur: 0.3; shadowOpacity: 0.3; shadowVerticalOffset: 1 }
        }
        MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor; onClicked: csw.toggled(!csw.on) }
    }
    component RoundBtn: Item {
        id: rb
        property string label: ""
        property color fill: "gray"
        property color ink: "white"
        property bool enabledBtn: true
        signal clicked()
        width: 78; height: 78
        opacity: enabledBtn ? 1 : 0.45
        Rectangle {
            anchors.fill: parent; radius: width / 2
            color: rb.fill
            border.width: 2; border.color: root.darkMode ? "#1C1C1E" : "#F2F2F7"
            scale: rbMa.pressed ? 0.94 : 1
            Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutQuint } }
            Behavior on color { ColorAnimation { duration: 220 } }
            Rectangle { anchors.fill: parent; anchors.margins: 3; radius: width / 2; color: "transparent"; border.width: 1.5; border.color: rb.fill }
            Text { anchors.centerIn: parent; text: rb.label; color: rb.ink; font.family: root.fam; font.pixelSize: 15; font.weight: Font.Medium }
        }
        MouseArea { id: rbMa; anchors.fill: parent; enabled: rb.enabledBtn; cursorShape: Qt.PointingHandCursor; onClicked: rb.clicked() }
    }
    component Ring: Canvas {
        id: rg
        property real frac: 1
        property color ink: "orange"
        property real lineW: 8
        property bool smoothFrac: false
        property real shown: frac
        Behavior on shown { enabled: rg.smoothFrac; NumberAnimation { duration: 1000; easing.type: Easing.Linear } }
        onShownChanged: requestPaint()
        onInkChanged: requestPaint()
        onWidthChanged: requestPaint()
        onPaint: {
            var c = getContext("2d"); c.reset();
            var r = width / 2 - lineW / 2;
            c.lineWidth = lineW; c.lineCap = "round"; c.strokeStyle = ink;
            c.beginPath();
            c.arc(width / 2, height / 2, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * Math.max(0.0001, shown), false);
            c.stroke();
        }
    }
    // analog face: white by day, black by night (macOS World Clock)
    component ClockFace: Item {
        id: cf
        property var date: new Date()
        property bool night: false
        property bool seconds: true
        readonly property color face: night ? "#1C1C1E" : "#F5F5F7"
        readonly property color ink: night ? "white" : "black"
        Rectangle { anchors.fill: parent; radius: width / 2; color: cf.face; border.width: cf.night ? 1 : 0; border.color: Qt.rgba(1, 1, 1, 0.12) }
        Repeater {
            model: cf.width >= 100 ? 0 : 12
            delegate: Item {
                required property int index
                anchors.fill: parent
                rotation: index * 30
                Rectangle { x: cf.width / 2 - width / 2; y: cf.width * 0.06; width: Math.max(1.5, cf.width * 0.016); height: cf.width * 0.07; radius: 1; color: cf.ink; opacity: 0.85 }
            }
        }
        Repeater {
            model: cf.width >= 100 ? 12 : 0
            delegate: Text {
                required property int index
                readonly property real a: (index + 1) * Math.PI / 6
                x: cf.width / 2 + Math.sin(a) * cf.width * 0.33 - width / 2
                y: cf.height / 2 - Math.cos(a) * cf.width * 0.33 - height / 2
                text: index + 1; color: cf.ink; font.family: root.fam; font.pixelSize: cf.width * 0.105; font.weight: Font.Medium
            }
        }
        // hour, minute, second hands
        Item {
            anchors.fill: parent
            rotation: (cf.date.getHours() % 12) * 30 + cf.date.getMinutes() * 0.5
            Rectangle { x: cf.width / 2 - width / 2; y: cf.height * 0.24; width: Math.max(3, cf.width * 0.035); height: cf.height * 0.28; radius: width / 2; color: cf.ink }
        }
        Item {
            anchors.fill: parent
            rotation: cf.date.getMinutes() * 6 + cf.date.getSeconds() * 0.1
            Rectangle { x: cf.width / 2 - width / 2; y: cf.height * 0.1; width: Math.max(2, cf.width * 0.025); height: cf.height * 0.42; radius: width / 2; color: cf.ink }
        }
        Item {
            anchors.fill: parent
            visible: cf.seconds
            rotation: cf.date.getSeconds() * 6
            Rectangle { x: cf.width / 2 - width / 2; y: cf.height * 0.08; width: Math.max(1, cf.width * 0.01); height: cf.height * 0.52; color: root.orange }
        }
        Rectangle { anchors.centerIn: parent; width: cf.width * 0.05; height: width; radius: width / 2; color: root.orange }
    }
}

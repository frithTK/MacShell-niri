// Independent session lock for niri; preview before configuring a PAM service.
import QtQuick
import "Locale" as Language
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Pam

ShellRoot {
    Language.LocaleRuntime {}
    // never hot-reload while holding the session lock: a half-edited config must not touch a live lock
    settings.watchFiles: false
    id: root
    readonly property bool preview: Quickshell.env("MACLOCK_PREVIEW") === "1"
    readonly property bool daemonMode: Quickshell.env("MACLOCK_DAEMON") === "1"
    // Default launch keeps the original behavior and locks immediately. In daemon mode, wait for IPC.
    property bool lockRequested: !daemonMode
    function requestLock() {
        if (!preview) lockRequested = true;
    }
    IpcHandler {
        target: "lockscreen"
        function state(): string {
            if (lock.wasSecure) return lock.secure ? "busy" : "stopping";
            return root.lockRequested ? "busy" : "ready";
        }
        function lock(): void { root.requestLock(); }
    }

    // the monitor that was focused when the lock started gets the full layout
    property string primary: ""
    function pickPrimary() { if (primary === "" && Quickshell.screens.length) primary = Quickshell.screens[0].name; }
    Component.onCompleted: pickPrimary()
    Process {
        running: true; command: ["niri", "msg", "-j", "focused-output"]
        stdout: StdioCollector { onStreamFinished: { try { var output = JSON.parse(text); if (output && output.name) root.primary = output.name; } catch (e) { root.pickPrimary(); } } }
    }

    QtObject {
        id: lockState
        property var now: new Date()
        property string wallpaper: ""
        property string wallpaperVideo: ""      // animated wallpaper set in MacShell (~/.config/macshell/wallpaper-video)
        property string userName: Quickshell.env("USER") || ""
        property string avatar: ""
        property int wifiLevel: -1          // -1 unknown/hidden, 0 off, 1..3 bars
        property bool ethernet: false       // wired connection up
        property string pass: ""
        property bool busy: false
        property int fails: 0
        property string message: ""
        property bool engaged: false
        property bool unlocking: false
        property string mediaSlot: "top"    // "top" (under the clock) | "bottom" (above the password field)
        property bool capsLock: false
        readonly property string keyboardLayout: keyboardLayout.name
        property bool use24h: true          // MacShell → Menu Bar → "24-hour clock"
        readonly property var clockSt: {
            try { return clockFile.loaded ? JSON.parse(clockFile.text()) : null; }
            catch (e) { return null; }
        }
        readonly property bool bootClockReady: bootClock.ready
        readonly property string bootClockId: bootClock.bootId
        readonly property double bootClockMs: bootClock.bootMs
        // Settings → Lock Screen → Clock (MACLOCK_CLOCK='{"f":"serif",...}' overrides it, for previews)
        property var clockCfg: { try { return JSON.parse(Quickshell.env("MACLOCK_CLOCK") || "{}"); } catch (e) { return {}; } }
        property bool artBg: true           // blurred album art behind everything while the cover is enlarged (MacShell setting)
        property bool sounds: false         // MacShell's "Play user interface sound effects" (and not in Game Mode)
        function sound(name) {
            if (sounds) Quickshell.execDetached(["pw-play", "--volume=0.7", Quickshell.env("HOME") + "/.local/share/sounds/macshell/" + name + ".wav"]);
        }
        // Now Playing presentation: "" (bubble), "art" (cover floats out, tap the cover) or "lyrics" (lyrics button)
        property string npMode: Quickshell.env("MACLOCK_NP") || (Quickshell.env("MACLOCK_ART") === "1" ? "art" : "")

        function setMediaSlot(v) {
            if (v === mediaSlot) return;
            mediaSlot = v;
            saveProc.command = ["sh", "-c", "mkdir -p \"${MACSHELL_SETTINGS_HOME:-$HOME/.config}/maclock\" && printf '{\\n  \"mediaSlot\": \"%s\"\\n}\\n' \"$1\" > \"${MACSHELL_SETTINGS_HOME:-$HOME/.config}/maclock/settings.json\"", "sh", v];
            saveProc.running = true;
        }
        function checkCaps() { if (!capsProc.running) capsProc.running = true; }

        function poke() {
            engaged = true;
            idleTimer.restart();
        }
        function submit() {
            if (busy || unlocking || pass.length === 0) return;
            busy = true;
            message = "";
            if (!pam.start()) { busy = false; fail(Language.I18n.text("ui.t_5766f52bf9ab")); }
        }
        function fail(msg) {
            pass = "";
            message = msg;
            fails++;
            msgTimer.restart();
        }
        function unlock() {
            unlocking = true;
            sound("unlock");
            unlockTimer.start();
        }
    }

    KeyboardLayout { id: keyboardLayout; active: root.preview || root.lockRequested }

    FileView {
        id: clockFile
        path: (Quickshell.env("MACSHELL_SETTINGS_HOME") || Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/macshell/clock.json"
        watchChanges: true; printErrors: false
        onFileChanged: reload()
    }
    BootClock {
        id: bootClock
        active: {
            var state = lockState.clockSt, timing = state && state.version === 2 && state.timing;
            if (!timing || timing.version !== 1) return false;
            var timer = timing.timer, sw = timing.stopwatch;
            return !!((timer && (timer.state === "running" || timer.state === "paused")) ||
                      (sw && (sw.state === "running" || sw.state === "paused")));
        }
        continuous: {
            var state = lockState.clockSt, timing = state && state.version === 2 && state.timing;
            if (!timing || timing.version !== 1) return false;
            return !!((timing.timer && timing.timer.state === "running") ||
                      (timing.stopwatch && timing.stopwatch.state === "running"));
        }
    }

    Process { id: saveProc }
    // Caps Lock indicator
    Process {
        id: capsProc
        command: ["sh", "-c", "for f in /sys/class/leds/*::capslock/brightness; do [ -r \"$f\" ] && [ \"$(cat \"$f\")\" = 1 ] && { echo true; exit; }; done; echo false"]
        stdout: StdioCollector {
            onStreamFinished: lockState.capsLock = text.trim() === "true"
        }
    }
    Timer { interval: 700; repeat: true; running: true; triggeredOnStart: true; onTriggered: lockState.checkCaps() }

    Timer { interval: 1000; running: true; repeat: true; triggeredOnStart: true; onTriggered: lockState.now = new Date() }
    // preview-only test hook: MACLOCK_TEST_MORPH=1 flips 12/24-hour every 1.5 s so the clock morph can be checked
    Timer { interval: 1500; repeat: true; running: root.preview && Quickshell.env("MACLOCK_TEST_MORPH") === "1"; onTriggered: lockState.use24h = !lockState.use24h }
    Timer { id: idleTimer; interval: 9000; onTriggered: if (lockState.pass.length === 0 && !lockState.busy) lockState.engaged = false }
    Timer { id: msgTimer; interval: 3500; onTriggered: lockState.message = "" }
    // let the exit animation play, then drop the lock and quit
    Timer {
        id: unlockTimer
        interval: 430
        onTriggered: {
            if (root.preview) Qt.quit();
            else {
                root.lockRequested = false;
                // A WlSessionLock is single-use in practice: retire this process after unlock so
                // the next IPC launch creates a fresh session-lock object.
                quitTimer.start();
            }
        }
    }
    Timer { id: quitTimer; interval: 150; onTriggered: Qt.quit() }

    PamContext {
        id: pam
        configDirectory: "/etc/pam.d"
        config: Quickshell.env("MACLOCK_PAM_SERVICE") || "login"
        onPamMessage: {
            if (this.responseRequired) this.respond(lockState.pass);
        }
        onCompleted: result => {
            lockState.busy = false;
            if (result === PamResult.Success) lockState.unlock();
            else lockState.fail(result === PamResult.MaxTries ? Language.I18n.text("ui.t_46517f2ed9bc") : Language.I18n.text("auth.incorrect_password"));
        }
        onError: err => {
            lockState.busy = false;
            lockState.fail(Language.I18n.text("ui.t_be6e6b8db7e6"));
        }
    }

    // Resolve wallpaper paths independently of slower network/profile probes so the lock scene can decode them immediately.
    Process {
        running: true
        command: ["sh", "-c",
            "p=$(jq -r '.wallpaperPath // empty' \"${MACSHELL_SETTINGS_HOME:-$HOME/.config}/macbar/settings.json\" 2>/dev/null); "
            + "[ -f \"$p\" ] || p=$(jq -r '.wallpaperPath // empty' \"${MACSHELL_SETTINGS_HOME:-$HOME/.config}/macdock/settings.json\" 2>/dev/null); "
            + "[ -f \"$p\" ] || p=$(awww query 2>/dev/null | sed -n 's/.*image: //p' | head -n1); "
            + "printf '%s\\n' \"$p\"; "
            + "v=$(cat \"${MACSHELL_SETTINGS_HOME:-$HOME/.config}/macshell/wallpaper-video-play\" 2>/dev/null); [ -f \"$v\" ] || v=$(cat \"${MACSHELL_SETTINGS_HOME:-$HOME/.config}/macshell/wallpaper-video\" 2>/dev/null); "
            + "[ -f \"${MACSHELL_SETTINGS_HOME:-$HOME/.config}/macshell/wallpaper-video\" ] && [ -f \"$v\" ] && printf '%s' \"$v\"; echo"]
        stdout: StdioCollector {
            onStreamFinished: {
                var l = text.split("\n");
                lockState.wallpaper = (l[0] || "").trim();
                lockState.wallpaperVideo = (l[1] || "").trim();
            }
        }
    }

    // ── one-shot lookups: real name, avatar, wifi, and other settings
    Process {
        running: true
        command: ["sh", "-c",
            "n=$(getent passwd \"$USER\" | cut -d: -f5 | cut -d, -f1); printf '%s\\n' \"${n:-$USER}\"; "
            + "for a in \"$HOME/.face\" \"$HOME/.face.icon\" \"/var/lib/AccountsService/icons/$USER\"; do [ -f \"$a\" ] && { printf '%s' \"$a\"; break; }; done; echo; "
            + "if [ \"$(nmcli radio wifi 2>/dev/null)\" = enabled ]; then s=$(nmcli -t -f ACTIVE,SIGNAL dev wifi 2>/dev/null | grep '^yes' | head -n1 | cut -d: -f2); "
            + "[ -n \"$s\" ] && printf '%s' \"$s\" || printf 0; else printf -- -1; fi; echo; "
            + "nmcli -t -f TYPE,STATE dev 2>/dev/null | grep -q '^ethernet:connected$' && echo eth || echo -; "
            + "jq -r '.mediaSlot // \"top\"' \"${MACSHELL_SETTINGS_HOME:-$HOME/.config}/maclock/settings.json\" 2>/dev/null || echo top; "
            + "[ \"$(jq -r '.uiSounds' \"${MACSHELL_SETTINGS_HOME:-$HOME/.config}/macbar/settings.json\" 2>/dev/null)\" != false ] && [ ! -f \"${XDG_RUNTIME_DIR:-/tmp}/macshell-gaming.state\" ] && echo snd || echo -; "
            + "jq -r '.lockArtBackground' \"${MACSHELL_SETTINGS_HOME:-$HOME/.config}/macbar/settings.json\" 2>/dev/null || echo true; "
            + "jq -r '.use24h' \"${MACSHELL_SETTINGS_HOME:-$HOME/.config}/macbar/settings.json\" 2>/dev/null || echo true; "
            + "jq -c '{f: .lockClockFont, w: .lockClockWeight, m: .lockClockMaterial, t: .lockClockTall, d: .lockClockDate, i: .lockClockIntensity, c: .lockClockTint}' \"${MACSHELL_SETTINGS_HOME:-$HOME/.config}/macbar/settings.json\" 2>/dev/null || echo '{}'"]
        stdout: StdioCollector {
            onStreamFinished: {
                var l = text.split("\n");
                if ((l[0] || "").trim() !== "") lockState.userName = l[0].trim();
                lockState.avatar = (l[1] || "").trim();
                var s = parseInt((l[2] || "-1").trim());
                lockState.wifiLevel = isNaN(s) || s < 0 ? -1 : (s === 0 ? 0 : (s > 66 ? 3 : (s > 33 ? 2 : 1)));
                lockState.ethernet = (l[3] || "").trim() === "eth";
                lockState.mediaSlot = (l[4] || "top").trim() === "bottom" ? "bottom" : "top";
                lockState.sounds = (l[5] || "").trim() === "snd";
                lockState.artBg = (l[6] || "true").trim() !== "false";
                lockState.use24h = (l[7] || "true").trim() !== "false";
                if (!Quickshell.env("MACLOCK_CLOCK")) { try { lockState.clockCfg = JSON.parse((l[8] || "{}").trim() || "{}"); } catch (e) { } }
                if (!root.preview) lockState.sound("lock");
            }
        }
    }

    // ═════════════ the real lock ═════════════
    WlSessionLock {
        id: lock
        locked: root.lockRequested && !root.preview
        // If this instance ever stops holding the lock without unlocking itself (another locker took over, the
        // compositor ended it, …), quit: a leftover instance keeps maclock.sh's one-locker guard and every later
        // lock attempt would silently do nothing.
        property bool wasSecure: false
        onSecureChanged: {
            if (secure) { wasSecure = true; return; }
            if (wasSecure && !root.preview && root.lockRequested) { console.log("[maclock] lost the session lock: quitting"); quitTimer.start(); }
        }

        WlSessionLockSurface {
            id: surf
            // transparent + the session lock surface: the lock fades in over the desktop and fades out to it
            color: "transparent"
            LockScreen {
                anchors.fill: parent
                st: lockState
                isPrimary: root.primary === "" || surf.screen === null || surf.screen.name === root.primary
            }
        }
    }

    // ═════════════ preview window ═════════════
    Variants {
        model: root.preview ? Quickshell.screens : []
        PanelWindow {
            id: pw
            required property var modelData
            screen: modelData
            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "maclock-preview"
            WlrLayershell.keyboardFocus: Quickshell.env("MACLOCK_PREVIEW_KB") === "1" && modelData.name === root.primary ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
            LockScreen {
                anchors.fill: parent
                st: lockState
                isPrimary: root.primary === "" || pw.modelData.name === root.primary
            }
        }
    }
}

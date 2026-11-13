import QtQuick
import Quickshell
import Quickshell.Io

// Listens on fprintd while the session is locked. The password field keeps working in parallel;
// after the attempt limit only the password unlocks this lock.
Scope {
    id: root
    property bool active: false
    property string launcher: decodeURIComponent(Qt.resolvedUrl("fingerprint-unlock.sh").toString().replace(/^file:\/\//, ""))
    // off | starting | scanning | retry | rejected | matched | locked_out | no_finger | unavailable
    property string phase: "off"
    property string scanType: ""
    property string hint: ""
    property int attempts: 0
    property int maxAttempts: 5
    property bool lockedOut: false
    property bool permanent: false
    property int failures: 0
    property bool gotResult: false
    property bool sawOutput: false
    readonly property bool listening: phase === "scanning" || phase === "retry" || phase === "rejected"
    signal matched()
    signal rejected()
    signal exhausted()

    function begin() {
        if (!active || lockedOut || permanent || proc.running) return;
        gotResult = false;
        sawOutput = false;
        hint = "";
        phase = "starting";
        proc.running = true;
    }
    function end() {
        retry.stop();
        if (proc.running) proc.write("cancel\n");
        if (!lockedOut && !permanent && phase !== "matched") phase = "off";
    }
    function scheduleRetry() {
        if (!active || lockedOut || permanent) return;
        retry.interval = Math.min(60000, 2000 * Math.pow(2, Math.min(failures, 5)));
        failures++;
        retry.restart();
    }
    function accept(line) {
        var message;
        try { message = JSON.parse(line); } catch (e) { return; }
        if (!message || typeof message !== "object") return;
        sawOutput = true;
        if (message.type === "device") {
            scanType = message.scanType === "press" || message.scanType === "swipe" ? message.scanType : "";
            return;
        }
        if (message.type === "status") {
            var code = String(message.code || "");
            if (code === "scan") {
                phase = "scanning";
                failures = 0;
                attempts = Number(message.stage || 0);
                maxAttempts = Number(message.total || maxAttempts);
            } else if (code === "verify-no-match") {
                attempts = Number(message.stage || attempts + 1);
                maxAttempts = Number(message.total || maxAttempts);
                phase = "rejected";
                rejected();
            } else if (code.indexOf("verify-") === 0) {
                hint = code;
                phase = "retry";
            }
            return;
        }
        if (message.type !== "result") return;
        gotResult = true;
        var result = String(message.code || "");
        if (message.success === true && result === "verify-match") {
            phase = "matched";
            matched();
        } else if (result === "too_many_attempts") {
            lockedOut = true;
            phase = "locked_out";
            exhausted();
        } else if (result === "no_finger") {
            permanent = true;
            phase = "no_finger";
        } else if (result === "permission") {
            permanent = true;
            phase = "unavailable";
        } else if (result !== "cancelled") {
            phase = "unavailable";
        }
    }
    onActiveChanged: active ? begin() : end()

    Process {
        id: proc
        command: ["sh", root.launcher]
        stdinEnabled: true
        stdout: SplitParser { onRead: line => root.accept(line) }
        onExited: (code, status) => {
            if (!root.active || root.lockedOut || root.permanent || root.phase === "matched") return;
            if (!root.gotResult && !root.sawOutput && code !== 0) {
                root.phase = "unavailable";
                root.failures = Math.max(root.failures, 4);
            } else if (root.phase !== "unavailable") {
                root.phase = "unavailable";
            }
            root.scheduleRetry();
        }
    }
    Timer { id: retry; repeat: false; onTriggered: root.begin() }
}

import QtQuick
import Quickshell
import "." as Port

ShellRoot {
    id: root
    property int phase: 0
    property int writes: 0
    Port.TimedModes {
        id: modes
        enabled: true
        saved: ({focus: {mode: "manual", future: "keep"}, awake: {mode: "manual", boot: Quickshell.env("TEST_BOOT"), session: "qml-test-session"}})
        onPersist: value => { root.writes++; }
    }
    Timer {
        interval: 100; repeat: true; running: true
        onTriggered: {
            if (root.phase === 0 && modes.restored) {
                if (!modes.active("focus") || !modes.active("awake") || modes.values.focus.future !== "keep") {
                    console.error("TIMED_RUST_FAIL restore"); Qt.exit(1); return;
                }
                root.phase = 1; modes.set("awake", "off");
            } else if (root.phase === 1 && modes.values.awake.mode === "off") {
                root.phase = 2; modes.set("focus", "15");
            } else if (root.phase === 2 && modes.values.focus.mode === "15") {
                if (!modes.remaining.focus || root.writes < 3) { console.error("TIMED_RUST_FAIL persist"); Qt.exit(1); return; }
                modes.enabled = false;
                console.log("TIMED_RUST_QML_PASS"); Qt.exit(0);
            }
        }
    }
    Timer { interval: 12000; running: true; onTriggered: { console.error("TIMED_RUST_FAIL timeout phase=" + root.phase); Qt.exit(1); } }
}

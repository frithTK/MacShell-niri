import QtQuick
import Quickshell
import "." as Port

ShellRoot {
    id: root
    property int phase: 0
    Port.ClockClient {
        id: client
        enabled: true
        storePath: Quickshell.env("MACSHELL_CLOCK_TEST_STORE")
        onSnapshotChanged: {
            if (!snapshot || !snapshot.timing) return;
            var event = snapshot.timing.completion;
            if (event && event.eventId === "event-a" && root.phase === 1) {
                if (error !== "Clock sound playback failed") {
                    console.error("CLOCK_CLIENT_FAIL playback error lost on state"); Qt.exit(1); return;
                }
                root.phase = 2;
                if (!submit("test", {})) { console.error("CLOCK_CLIENT_FAIL submit"); Qt.exit(1); }
            } else if (event && event.eventId === "event-b" && root.phase === 3) {
                Qt.callLater(function() {
                    if (client.error !== "" || client.playbackErrorEventId !== "") {
                        console.error("CLOCK_CLIENT_FAIL stale playback error"); Qt.exit(1); return;
                    }
                    console.log("CLOCK_CLIENT_PASS"); Qt.exit(0);
                });
            }
        }
        onErrorChanged: if (error === "Clock sound playback failed" && root.phase === 0) root.phase = 1
        onCompleted: (success, result, detail) => {
            if (!success || error !== "Clock sound playback failed") {
                console.error("CLOCK_CLIENT_FAIL playback error lost on command"); Qt.exit(1); return;
            }
            root.phase = 3;
        }
    }
    Timer { interval: 8000; running: true; onTriggered: { console.error("CLOCK_CLIENT_FAIL timeout " + root.phase); Qt.exit(1); } }
}

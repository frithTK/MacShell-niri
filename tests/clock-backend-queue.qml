import QtQuick
import Quickshell
import "." as Port

ShellRoot {
    id: root
    property int phase: 0
    Port.ClockBackend {
        id: clock
        enabled: true
        storePath: Quickshell.env("MACSHELL_CLOCK_TEST_STORE")
        onCompleted: (action, success, result, error) => {
            if (!success) { console.error("CLOCK_QUEUE_FAIL " + action + " " + error); Qt.exit(1); }
        }
    }
    Timer {
        interval: 50; running: true; repeat: true
        onTriggered: {
            if (!clock.ready) return;
            if (root.phase === 0 && clock.completion) {
                root.phase = 1;
                if (!clock.patchSettings({recents: [60000]}) || !clock.eventAction("dismiss-event")) {
                    console.error("CLOCK_QUEUE_FAIL submit"); Qt.exit(1);
                }
            } else if (root.phase === 1 && !clock.busy && !clock.completion && !clock.queuedEvent) {
                console.log("CLOCK_QUEUE_PASS"); Qt.exit(0);
            }
        }
    }
    Timer { interval: 10000; running: true; onTriggered: { console.error("CLOCK_QUEUE_FAIL timeout"); Qt.exit(1); } }
}

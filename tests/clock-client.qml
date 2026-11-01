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
        onErrorChanged: if (error) console.error("CLOCK_CLIENT_ERROR " + error)
        onReadyChanged: {
            if (ready && root.phase === 0) {
                root.phase = 1;
                var sound = Quickshell.env("MACSHELL_CLOCK_TEST_ACTION") === "claim-sound";
                var action = sound ? "claim-sound" : "start";
                var args = sound ? {eventId: client.snapshot.timing.completion.eventId} : {durationMs: 10000, label: "Client test"};
                if (!client.submit(action, args)) {
                    console.error("CLOCK_CLIENT_FAIL submit"); Qt.exit(1);
                }
            }
        }
        onCompleted: (success, result, error) => {
            if (Quickshell.env("MACSHELL_CLOCK_TEST_ACTION") === "claim-sound") {
                if (success || error.indexOf("outcome is unknown") < 0 || !client.snapshot.timing.completion.soundClaimed) {
                    console.error("CLOCK_CLIENT_FAIL unsafe sound retry"); Qt.exit(1); return;
                }
                console.log("CLOCK_CLIENT_PASS"); Qt.exit(0); return;
            }
            if (!success || !result || result.timer.state !== "running" || result.timer.label !== "Client test") {
                console.error("CLOCK_CLIENT_FAIL " + error); Qt.exit(1); return;
            }
            console.log("CLOCK_CLIENT_PASS"); Qt.exit(0);
        }
    }
    Timer { interval: 8000; running: true; onTriggered: { console.error("CLOCK_CLIENT_FAIL timeout enabled=" + client.enabled + " store=" + client.storePath + " ready=" + client.ready + " initialized=" + client.initialized + " error=" + client.error + " service=" + client.serviceError); Qt.exit(1); } }
}

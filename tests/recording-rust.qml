import QtQuick
import Quickshell
import "." as Port

ShellRoot {
    id: root
    property int phase: 0
    Port.RecordingControl { id: recording; active: true }
    Timer {
        interval: 100; repeat: true; running: true
        onTriggered: {
            if (root.phase === 0) {
                if (recording.outputs.length === 0) recording.prepare();
                else { root.phase = 1; recording.audio = "none"; recording.start(); }
            } else if (root.phase === 1 && recording.state === "recording") {
                root.phase = 2; recording.stop();
            } else if (root.phase === 2 && recording.state === "result") {
                console.log("RECORDING_RUST_QML_PASS"); Qt.exit(0);
            }
        }
    }
    Timer { interval: 12000; running: true; onTriggered: { console.error("RECORDING_RUST_QML_FAIL phase=" + root.phase + " " + recording.error); Qt.exit(1); } }
}

import QtQuick
import Quickshell
import "." as Port

ShellRoot {
    id: root
    property bool started: false
    property bool cancelled: false
    property bool finished: false
    property bool probing: false
    Port.ClockSoundImport {
        id: importer
        directory: Quickshell.env("CLOCK_TEST_LIBRARY")
        onFinished: root.finished = true
    }
    Timer {
        interval: 100; running: true; repeat: true
        property int ticks: 0
        onTriggered: {
            if (!root.started) {
                if (!root.probing) { root.probing = true; importer.probeCodecs(); return; }
                if (!importer.codecsProbed) return;
                if (!importer.aacSupported) { console.error("CLOCK_IMPORT_CANCEL_FAIL AAC discovery"); Qt.exit(1); return; }
                root.started = true;
                importer.importFiles(["file://" + Quickshell.env("CLOCK_TEST_FILE"), "file://" + Quickshell.env("CLOCK_TEST_FILE")]);
            } else if (root.cancelled && root.finished && !importer.busy) {
                console.log("CLOCK_IMPORT_CANCEL_PASS"); Qt.exit(0);
            } else if (!root.cancelled && importer.busy && ++ticks >= 10) {
                root.cancelled = true; importer.cancel();
            }
        }
    }
    Timer { interval: 8000; running: true; onTriggered: { console.error("CLOCK_IMPORT_CANCEL_FAIL busy=" + importer.busy + " error=" + importer.error); Qt.exit(1); } }
}

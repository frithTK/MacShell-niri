import QtQuick
import Quickshell
import "." as Port

ShellRoot {
    id: root
    property int phase: 0
    Port.ActivityPreferences {
        id: preferences
        enabled: true
        onFinished: success => {
            if (!success) { console.error("ACTIVITY_RUST_FAIL " + preferences.error); Qt.exit(1); return; }
            if (root.phase === 1 && preferences.values.cpuWarning === 42) {
                console.log("ACTIVITY_RUST_QML_PASS"); Qt.exit(0);
            }
        }
    }
    Timer {
        interval: 100; repeat: true; running: true
        onTriggered: {
            if (root.phase === 0 && preferences.ready && !preferences.pending) {
                if (preferences.readOnly || !preferences.fields.length) { console.error("ACTIVITY_RUST_FAIL load"); Qt.exit(1); return; }
                let values = Object.assign({}, preferences.values);
                values.cpuWarning = 42;
                root.phase = 1;
                preferences.save(values, preferences.token);
            }
        }
    }
    Timer { interval: 12000; running: true; onTriggered: { console.error("ACTIVITY_RUST_FAIL timeout phase=" + root.phase); Qt.exit(1); } }
}

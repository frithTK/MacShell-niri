import QtQuick
import Quickshell
import "." as Port

ShellRoot {
    id: root
    property int phase: 0
    Port.WidgetPreferences {
        id: preferences
        origin: ({name: "DP-1", width: 1920, height: 1080})
        onFinished: success => {
            if (!success) { console.error("WIDGET_RUST_FAIL " + preferences.error); Qt.exit(1); return; }
            if (root.phase === 1 && preferences.values.enabled === false) {
                console.log("WIDGET_RUST_QML_PASS"); Qt.exit(0);
            }
        }
    }
    Timer {
        interval: 100; repeat: true; running: true
        onTriggered: {
            if (root.phase === 0 && preferences.ready && !preferences.pending && !preferences.loading) {
                if (preferences.readOnly) { console.error("WIDGET_RUST_FAIL read-only"); Qt.exit(1); return; }
                let values = JSON.parse(JSON.stringify(preferences.values)); values.enabled = false;
                root.phase = 1; preferences.save(values);
            }
        }
    }
    Timer { interval: 12000; running: true; onTriggered: { console.error("WIDGET_RUST_FAIL timeout phase=" + root.phase); Qt.exit(1); } }
}

import QtQuick
import Quickshell
import "." as Port

ShellRoot {
    id: root
    property int phase: 0
    Port.BarPreferences {
        id: preferences
        enabled: true
        onFinished: success => {
            if (!success) { console.error("BAR_RUST_FAIL " + preferences.error); Qt.exit(1); return; }
            if (root.phase === 1 && !preferences.commonEnabled("clock")) {
                console.log("BAR_RUST_QML_PASS"); Qt.exit(0);
            }
        }
    }
    Timer {
        interval: 100; repeat: true; running: true
        onTriggered: {
            if (root.phase === 0 && preferences.ready && !preferences.pending) {
                if (preferences.readOnly || !preferences.catalog.length || !preferences.commonEnabled("clock")) { console.error("BAR_RUST_FAIL load"); Qt.exit(1); return; }
                root.phase = 1; preferences.setEnabled("clock", false);
            }
        }
    }
    Timer { interval: 12000; running: true; onTriggered: { console.error("BAR_RUST_FAIL timeout phase=" + root.phase); Qt.exit(1); } }
}

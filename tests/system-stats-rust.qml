import QtQuick
import Quickshell
import "." as Port

ShellRoot {
    id: root
    property int phase: 0
    Port.SystemStats { id: stats; enabled: true }
    Timer {
        interval: 100; running: true; repeat: true
        onTriggered: {
            if (root.phase === 0 && stats.lastSample > 0 && stats.sample.type === "sample") {
                if (!stats.sample.memory || !stats.sample.memory.total) { console.error("STATS_RUST_FAIL memory"); Qt.exit(1); return; }
                root.phase = 1;
                stats.interfaceName = "macshell-no-such-interface";
                stats.device = "macshell-no-such-device";
            } else if (root.phase === 1 && stats.sample.diskLabel === "Selected block device is unavailable") {
                if (stats.sample.interface !== "" || stats.sample.network !== null || stats.sample.disk !== null) {
                    console.error("STATS_RUST_FAIL missing device"); Qt.exit(1); return;
                }
                stats.enabled = false;
                console.log("STATS_RUST_QML_PASS"); Qt.exit(0);
            }
        }
    }
    Timer { interval: 12000; running: true; onTriggered: { console.error("STATS_RUST_FAIL timeout phase=" + root.phase + " error=" + stats.error); Qt.exit(1); } }
}

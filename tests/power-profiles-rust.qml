import QtQuick
import Quickshell
import "." as Port

ShellRoot {
    id: root
    property int phase: 0
    Port.PowerControl { id: power }
    Timer {
        interval: 100; repeat: true; running: true
        onTriggered: {
            if (root.phase === 0 && power.available && !power.busy && power.profile === "balanced") {
                root.phase = 1; power.select("power-saver");
            } else if (root.phase === 1 && power.available && !power.busy && power.profile === "power-saver") {
                root.phase = 2; power.gaming = true;
            } else if (root.phase === 2 && power.available && !power.busy && power.profile === "performance" && power.gameHold) {
                root.phase = 3; power.gaming = false;
            } else if (root.phase === 3 && power.available && !power.busy && power.profile === "power-saver" && !power.gameHold) {
                console.log("POWER_RUST_QML_PASS"); Qt.exit(0);
            }
        }
    }
    Timer { interval: 12000; running: true; onTriggered: { console.error("POWER_RUST_FAIL timeout phase=" + root.phase + " " + power.error); Qt.exit(1); } }
}

import QtQuick
import Quickshell
import "." as Port

ShellRoot {
    id: root
    property int phase: 0
    Port.NightShiftControl { id: shift; active: true; desired: true; temperature: 4100 }
    Timer {
        interval: 100; repeat: true; running: true
        onTriggered: {
            if (root.phase === 0 && shift.state === "on") {
                if (!shift.available || shift.appliedTemperature !== 4100) { console.error("NIGHT_RUST_FAIL applied"); Qt.exit(1); return; }
                root.phase = 1;
                shift.desired = false;
            } else if (root.phase === 1 && shift.state === "off") {
                console.log("NIGHT_RUST_QML_PASS"); Qt.exit(0);
            }
        }
    }
    Timer { interval: 12000; running: true; onTriggered: { console.error("NIGHT_RUST_FAIL timeout phase=" + root.phase + " state=" + shift.state + " error=" + shift.error); Qt.exit(1); } }
}

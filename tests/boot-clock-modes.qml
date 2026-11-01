import QtQuick
import Quickshell
import "." as Port

ShellRoot {
    id: root
    property int phase: 0
    property bool continuous: false
    Port.BootClock { id: clock; active: true; continuous: root.continuous }
    Timer {
        interval: 50; running: true; repeat: true
        onTriggered: {
            if (root.phase === 0 && clock.ready && !clock.sampling) { root.phase = 1; root.continuous = true; }
            else if (root.phase === 1 && clock.ready && clock.sampling) { root.phase = 2; root.continuous = false; }
            else if (root.phase === 2 && clock.ready && !clock.sampling) { console.log("MACLOCK_BOOT_MODES_PASS"); Qt.exit(0); }
        }
    }
    Timer { interval: 10000; running: true; onTriggered: { console.error("MACLOCK_BOOT_MODES_FAIL"); Qt.exit(1); } }
}

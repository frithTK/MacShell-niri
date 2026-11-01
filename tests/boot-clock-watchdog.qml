import QtQuick
import Quickshell
import "." as Port

ShellRoot {
    id: root
    property bool sawSample: false
    Port.BootClock {
        id: clock
        active: true
        onReadyChanged: {
            if (ready) root.sawSample = true;
            else if (root.sawSample) { console.log("MACLOCK_BOOT_WATCHDOG_PASS"); Qt.exit(0); }
        }
    }
    Timer { interval: 6000; running: true; onTriggered: { console.error("MACLOCK_BOOT_WATCHDOG_FAIL"); Qt.exit(1); } }
}

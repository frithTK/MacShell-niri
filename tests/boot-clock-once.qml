import QtQuick
import Quickshell
import "." as Port

ShellRoot {
    Port.BootClock {
        id: clock
        active: true
        continuous: false
        onReadyChanged: if (ready) check.start()
    }
    Timer {
        id: check; interval: 500
        onTriggered: {
            if (clock.ready && !clock.sampling && clock.bootId !== "") {
                console.log("MACLOCK_BOOT_ONCE_PASS"); Qt.exit(0);
            } else { console.error("MACLOCK_BOOT_ONCE_FAIL"); Qt.exit(1); }
        }
    }
    Timer { interval: 6000; running: true; onTriggered: { console.error("MACLOCK_BOOT_ONCE_FAIL timeout"); Qt.exit(1); } }
}

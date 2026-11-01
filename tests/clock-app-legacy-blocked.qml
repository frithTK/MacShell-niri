import QtQuick
import Quickshell
import "." as Port

ShellRoot {
    Port.ClockApp { id: clock }
    Timer {
        interval: 100; running: true; repeat: true
        onTriggered: {
            if (!clock.loaded) return;
            if (!clock.legacyStoreBlocked || clock.clockControlsReady || clock.startTimer(10000, "unsafe") ||
                    clock.addAlarm(12, 0, "unsafe", [])) {
                console.error("CLOCK_LEGACY_GUARD_FAIL"); Qt.exit(1); return;
            }
            clock.saveNow();
            console.log("CLOCK_LEGACY_GUARD_PASS"); Qt.exit(0);
        }
    }
    Timer { interval: 8000; running: true; onTriggered: { console.error("CLOCK_LEGACY_GUARD_FAIL timeout"); Qt.exit(1); } }
}

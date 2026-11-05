import QtQuick
import Quickshell
import "." as Lock

ShellRoot {
    id: root
    property int step: 0
    Lock.KeyboardLayout { id: layout }
    Timer {
        interval: 30; repeat: true; running: true
        onTriggered: {
            var expected = ["English (US)", "Russian", "", "English (US)", "", "Russian", "Japanese", "", "Japanese"];
            if (layout.name !== expected[root.step]) return;
            console.log("MACLOCK_LAYOUT_STEP_" + root.step);
            if (++root.step === expected.length) { console.log("MACLOCK_LAYOUT_PASS"); Qt.quit(); }
        }
    }
    Timer { interval: 15000; running: true; onTriggered: { console.error("MACLOCK_LAYOUT_FAIL timeout step=" + root.step); Qt.exit(1); } }
}

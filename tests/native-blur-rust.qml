import QtQuick
import Quickshell
import "." as Port

ShellRoot {
    id: root
    property int phase: 0
    Port.NativeBlurControl { id: blur; active: true; level: 24 }
    Timer {
        interval: 100; repeat: true; running: true
        onTriggered: {
            if (root.phase === 0 && blur.available && !blur.managed) { root.phase = 1; blur.apply(); }
            else if (root.phase === 1 && blur.available && blur.managed && blur.appliedLevel === 24) {
                console.log("NATIVE_BLUR_RUST_QML_PASS"); Qt.exit(0);
            }
        }
    }
    Timer { interval: 12000; running: true; onTriggered: { console.error("NATIVE_BLUR_RUST_FAIL timeout phase=" + root.phase + " " + blur.error); Qt.exit(1); } }
}

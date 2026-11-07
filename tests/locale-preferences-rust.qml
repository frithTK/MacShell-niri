import QtQuick
import Quickshell
import "." as Port

ShellRoot {
    id: root
    property int phase: 0
    Port.LocaleControl {
        id: preferences
        onFinished: success => {
            if (!success) { console.error("LOCALE_RUST_FAIL " + preferences.errorCode); Qt.exit(1); return; }
            if (root.phase === 1 && preferences.values.ui === "ru" && preferences.values.session === "C") {
                console.log("LOCALE_RUST_QML_PASS"); Qt.exit(0);
            }
        }
    }
    Timer {
        interval: 100; repeat: true; running: true
        onTriggered: {
            if (root.phase === 0 && preferences.ready && !preferences.pending) {
                root.phase = 1;
                preferences.save({ui: "ru", session: "C", region: "system"}, preferences.token);
            }
        }
    }
    Timer { interval: 12000; running: true; onTriggered: { console.error("LOCALE_RUST_FAIL timeout phase=" + root.phase); Qt.exit(1); } }
}

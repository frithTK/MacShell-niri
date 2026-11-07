import QtQuick
import Quickshell
import "." as Port

ShellRoot {
    id: root
    property int phase: 0
    Port.WifiControl { id: wifi }
    Timer {
        interval: 100; repeat: true; running: true
        onTriggered: {
            if (root.phase === 0 && wifi.available && wifi.networks.length && wifi.networks[0].saved) {
                root.phase = 1; wifi.pick(wifi.networks[0]);
            } else if (root.phase === 1 && wifi.busy !== "") {
                root.phase = 2;
            } else if (root.phase === 2 && wifi.busy === "" && wifi.error === "") {
                console.log("WIFI_RUST_QML_PASS"); Qt.exit(0);
            }
        }
    }
    Timer { interval: 12000; running: true; onTriggered: { console.error("WIFI_RUST_QML_FAIL phase=" + root.phase + " " + wifi.error); Qt.exit(1); } }
}

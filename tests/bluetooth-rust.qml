import QtQuick
import Quickshell
import "." as Port

ShellRoot {
    id: root
    property int phase: 0
    Port.BluetoothControl { id: bluetooth }
    Timer {
        interval: 100; repeat: true; running: true
        onTriggered: {
            if (root.phase === 0 && bluetooth.stateReady && bluetooth.enabled && bluetooth.pairingAvailable && bluetooth.others.length) {
                root.phase = 1; bluetooth.discover();
            } else if (root.phase === 1 && bluetooth.discovering) {
                root.phase = 2; bluetooth.pair(bluetooth.others[0]);
            } else if (root.phase === 2 && bluetooth.prompt) {
                root.phase = 3; bluetooth.respond(true, "");
            } else if (root.phase === 3 && !bluetooth.busy && bluetooth.devices.length && bluetooth.devices[0].connected) {
                root.phase = 4; bluetooth.pick(bluetooth.devices[0]);
            } else if (root.phase === 4 && !bluetooth.busy && bluetooth.devices.length && !bluetooth.devices[0].connected) {
                root.phase = 5; bluetooth.togglePower();
            } else if (root.phase === 5 && !bluetooth.busy && bluetooth.stateReady && !bluetooth.enabled) {
                console.log("BLUETOOTH_RUST_QML_PASS"); Qt.exit(0);
            }
        }
    }
    Timer { interval: 14000; running: true; onTriggered: { console.error("BLUETOOTH_RUST_FAIL phase=" + root.phase + " " + bluetooth.error); Qt.exit(1); } }
}

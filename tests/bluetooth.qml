import QtQuick
import Quickshell

ShellRoot {
    id: test
    property int phase: 0
    BluetoothControl { id: bluetooth }
    function check(ok, message) {
        if (!ok) {
            console.error(message);
            Qt.exit(1);
        }
        return ok;
    }
    Timer {
        interval: 20; repeat: true; running: true
        onTriggered: {
            if (test.phase === 0 && !bluetooth.loading) {
                if (!test.check(bluetooth.enabled && bluetooth.devices.length === 1, "Initial Bluetooth status failed")) return;
                bluetooth.pick(bluetooth.devices[0]);
                bluetooth.pick(bluetooth.devices[0]);
                if (!test.check(bluetooth.busy && bluetooth.busyAction === "connect", "Busy state failed")) return;
                test.phase = 1;
            } else if (test.phase === 1 && !bluetooth.busy) {
                if (!test.check(bluetooth.error === "Test connection failure", "Failed connection feedback was lost")) return;
                if (!test.check(bluetooth.busyPath === "", "Busy device was not cleared")) return;
                bluetooth.togglePower();
                if (!test.check(bluetooth.error === "", "Stale error was not cleared")) return;
                test.phase = 2;
            } else if (test.phase === 2 && !bluetooth.busy && !bluetooth.enabled) {
                if (!test.check(bluetooth.error === "", "Power action failed")) return;
                console.log("MACSHELL_BLUETOOTH_PASS");
                Qt.exit(0);
            }
        }
    }
    Timer { interval: 6000; running: true; onTriggered: { console.error("Bluetooth test timed out in phase " + test.phase); Qt.exit(1); } }
}

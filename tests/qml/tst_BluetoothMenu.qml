import QtQuick
import QtTest
import "../../MacShell" as Port

TestCase {
    id: testCase
    name: "BluetoothMenu"
    width: 380; height: 600
    visible: true
    when: windowShown
    property var sample: ({path: "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF", name: "Headphones",
                          connected: true, adapterEnabled: true, blocked: false, battery: 75, icon: "audio-headset"})
    property var theme: ({fg: "#ffffff", fg2: "#b8bdca", accent: "#0a84ff", btnOff: "#414651",
                         hover: "#454c60", switchOff: "#565b66", sep: "#4c5260", fam: "sans-serif"})
    QtObject {
        id: fakeBluetooth
        property bool available: true
        property bool enabled: true
        property bool busy: false
        property bool loading: false
        property bool refreshing: false
        property string error: ""
        property string statusError: ""
        property var adapters: [{}]
        property var devices: []
        property int picks: 0
        property int toggles: 0
        property int refreshes: 0
        function togglePower() { toggles++; }
        function pick(device) { picks++; }
        function refresh() { refreshes++; }
        function deviceKind(device) { return device.icon === "audio-headset" ? "headphones" : "bluetooth"; }
        function deviceStatus(device) { return device.connected ? "Connected · 75%" : "Not Connected"; }
    }
    Rectangle { anchors.fill: parent; color: "#252a36" }
    Port.BluetoothMenu {
        id: menu
        x: 16; y: 16; width: 316
        t: testCase.theme; controller: fakeBluetooth
        maxListHeight: 180
    }
    function init() {
        fakeBluetooth.available = true;
        fakeBluetooth.enabled = true;
        fakeBluetooth.busy = false;
        fakeBluetooth.error = "";
        fakeBluetooth.statusError = "";
        fakeBluetooth.picks = 0;
        fakeBluetooth.toggles = 0;
        fakeBluetooth.devices = [sample];
        wait(20);
    }
    function test_device_selection_and_busy_guard() {
        var row = findChild(menu, "bluetoothDevice");
        verify(row !== null);
        mouseClick(row, row.width / 2, row.height / 2);
        compare(fakeBluetooth.picks, 1);
        fakeBluetooth.busy = true;
        mouseClick(row, row.width / 2, row.height / 2);
        compare(fakeBluetooth.picks, 1);
    }
    function test_power_switch_and_unavailable_guard() {
        var power = findChild(menu, "bluetoothPower");
        mouseClick(power, power.width / 2, power.height / 2);
        compare(fakeBluetooth.toggles, 1);
        fakeBluetooth.available = false;
        mouseClick(power, power.width / 2, power.height / 2);
        compare(fakeBluetooth.toggles, 1);
    }
    function test_blocked_device_cannot_be_selected() {
        fakeBluetooth.devices = [Object.assign({}, sample, {blocked: true})];
        wait(20);
        var row = findChild(menu, "bluetoothDevice");
        mouseClick(row, row.width / 2, row.height / 2);
        compare(fakeBluetooth.picks, 0);
    }
    function test_power_off_hides_devices() {
        fakeBluetooth.enabled = false;
        wait(20);
        compare(findChild(menu, "bluetoothDevice"), null);
    }
    function test_long_list_is_bounded_and_error_fits() {
        var rows = [];
        for (var i = 0; i < 20; i++) rows.push(Object.assign({}, sample, {path: "device-" + i}));
        fakeBluetooth.devices = rows;
        fakeBluetooth.error = "The device did not respond. Check that it is on and nearby.";
        wait(20);
        verify(menu.height < 430);
        verify(menu.height > 250);
    }
}

import QtQuick
import QtTest
import "../../MacShell" as Port

TestCase {
    id: test; name: "AirDrop"; when: windowShown
    width: 600; height: 800; visible: true
    QtObject {
        id: fake
        property var state: ({configured: true, canStart: true, mode: "shared", status: "off", notice: "", files: [], devices: [], pending: null, receiving: false, scanning: false, transfer: "idle", progress: {sent: 0, total: 0}, results: [], folder: "Downloads/AirDrop"})
        property string receiverName: "Test MacShell"
        property string error: ""
        property bool airplayBusy: false
        readonly property bool active: ["starting", "ready", "stopping"].indexOf(state.status) >= 0
        readonly property bool transferring: ["waiting", "sending", "receiving"].indexOf(state.transfer) >= 0
        readonly property string label: active ? "Everyone · 10 min" : "Off"
        property int starts: 0
        property int stops: 0
        property string sent: ""
        property string answered: ""
        property bool accepted: false
        signal showRequested()
        function refresh() {}
        function start() { starts++; }
        function stop() { stops++; }
        function setFiles(paths) {}
        function sendFiles(key) { sent = key; }
        function answer(key, accept) { answered = key; accepted = accept; }
        function cancel() {}
    }
    Component { id: windowComponent; Port.AirDropWindow { controller: fake } }
    function reset() {
        fake.state = {configured: true, canStart: true, mode: "shared", status: "off", notice: "", files: [], devices: [], pending: null, receiving: false, scanning: false, transfer: "idle", progress: {sent: 0, total: 0}, results: [], folder: "Downloads/AirDrop"};
        fake.starts = 0; fake.stops = 0; fake.airplayBusy = false; fake.sent = ""; fake.answered = "";
    }
    function test_explicit_enable_airplay_guard_and_stop_in_both_themes() {
        for (var foreground of ["#f5f5f7", "#1d1d1f"]) {
            reset();
            var window = createTemporaryObject(windowComponent, test, {foreground: foreground});
            window.open(); tryVerify(() => window.active);
            var toggle = findChild(window.contentItem, "airdropToggle");
            fake.airplayBusy = true; compare(toggle.enabled, false);
            fake.airplayBusy = false; mouseClick(toggle); compare(fake.starts, 1);
            fake.state = Object.assign({}, fake.state, {status: "ready"});
            mouseClick(toggle); compare(fake.stops, 1);
            window.hide(); window.destroy();
        }
    }
    function test_disruptive_modes_are_disabled_in_both_themes_but_stop_still_works() {
        for (var foreground of ["#f5f5f7", "#1d1d1f"]) {
            for (var mode of ["exclusive", "active-monitor"]) {
                reset();
                var window = createTemporaryObject(windowComponent, test, {foreground: foreground});
                window.open(); tryVerify(() => window.active);
                fake.state = Object.assign({}, fake.state, {mode: mode, canStart: false});
                var toggle = findChild(window.contentItem, "airdropToggle");
                compare(toggle.enabled, false); compare(toggle.text, "Unavailable on this adapter");
                mouseClick(toggle); compare(fake.starts, 0);
                fake.state = Object.assign({}, fake.state, {status: "ready"});
                verify(toggle.enabled); mouseClick(toggle); compare(fake.stops, 1);
                window.hide(); window.destroy();
            }
        }
    }
    function test_incoming_request_uses_its_key_and_escape_declines() {
        reset();
        var window = createTemporaryObject(windowComponent, test);
        fake.state = Object.assign({}, fake.state, {status: "ready", receiving: true, pending: {key: "session:3", name: "<Test iPhone>", files: [{name: "photo.jpg"}], urls: []}});
        fake.showRequested(); tryVerify(() => window.active); verify(window.receiveTab);
        var accept = findChild(window.contentItem, "airdropAccept");
        waitForRendering(accept); mouseClick(accept); compare(fake.answered, "session:3"); verify(fake.accepted);
        keyClick(Qt.Key_Escape); compare(fake.answered, "session:3"); compare(fake.accepted, false); tryCompare(window, "visible", false);
    }
    function test_send_requires_files_and_only_uses_selected_device() {
        reset();
        var window = createTemporaryObject(windowComponent, test);
        window.open(); tryVerify(() => window.active);
        fake.state = Object.assign({}, fake.state, {status: "ready", devices: [{key: "one", name: "Test iPhone"}]});
        var device = findChild(window.contentItem, "airdropDevice");
        verify(device !== null); compare(device.enabled, false);
        fake.state = Object.assign({}, fake.state, {files: [{name: "photo.jpg"}]});
        waitForRendering(device); mouseClick(device); compare(fake.sent, "one");
        fake.state = Object.assign({}, fake.state, {transfer: "waiting"}); compare(device.enabled, false);
        window.hide();
    }
}

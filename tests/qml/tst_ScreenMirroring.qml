import QtQuick
import QtTest
import "../../MacShell" as Port

TestCase {
    id: test
    name: "ScreenMirroring"
    when: windowShown
    width: 440; height: 800; visible: true
    QtObject {
        id: fake
        property bool senderAvailable: true
        property bool receiverAvailable: true
        property string senderState: "ready"
        property string receiverState: "off"
        property string senderError: ""
        property string receiverError: ""
        property string error: ""
        property string receiverName: "Test MacShell"
        property string advertisedName: "Test MacShell"
        property string receiverPin: ""
        property string receiverClient: ""
        property bool scanning: false
        property var devices: [{key: "test-tv", name: "Living Room", address: "192.0.2.1", port: 7000}]
        property var streams: []
        readonly property var pending: streams.find(s => s.state === "pin_required") || null
        readonly property bool sending: senderState === "streaming"
        readonly property bool connecting: ["starting", "connecting", "pin_required"].indexOf(senderState) >= 0
        readonly property bool receiving: ["starting", "waiting", "streaming"].indexOf(receiverState) >= 0
        property string chosen: ""
        property string credential: ""
        property int disconnects: 0
        property bool receiverDesired: false
        property bool audioDesired: true
        property string layout: "mirror"
        property bool extendAvailable: false
        property string extendOutput: ""
        property bool virtualOutputsSupported: false
        property string extendMethod: ""
        property string extendCapture: ""
        function refresh() { scanning = true; }
        function connectDevice(key) { chosen = key; }
        function submitCredential(value) { credential = value; }
        function disconnect() { disconnects++; }
        function setReceiver(enabled) { receiverDesired = enabled; }
        function setAudio(enabled) { audioDesired = enabled; }
    }
    Component { id: menuComponent; Port.ScreenMirroringMenu {} }
    property var menu: null
    function init() {
        fake.senderAvailable = true; fake.receiverAvailable = true;
        fake.senderState = "ready"; fake.receiverState = "off";
        fake.senderError = ""; fake.receiverError = ""; fake.error = "";
        fake.receiverName = "Test MacShell"; fake.receiverPin = ""; fake.receiverClient = "";
        fake.scanning = false; fake.streams = []; fake.chosen = ""; fake.credential = "";
        fake.disconnects = 0; fake.receiverDesired = false; fake.audioDesired = true;
        fake.layout = "mirror"; fake.extendAvailable = false; fake.extendOutput = "";
        fake.virtualOutputsSupported = false; fake.extendMethod = ""; fake.extendCapture = "";
        menu = createTemporaryObject(menuComponent, test, {controller: fake, width: 366});
        verify(menu !== null);
    }
    function test_devices_connect_and_search_are_independent_of_receiver() {
        mouseClick(findChild(menu, "mirroringDevice"));
        compare(fake.chosen, "test-tv");
        mouseClick(findChild(menu, "mirroringRefresh"));
        compare(fake.scanning, true);
        compare(findChild(menu, "mirroringRefresh").enabled, false);
        compare(fake.receiverDesired, false);
    }
    function test_pending_pin_keeps_leading_zeroes_and_clears_after_submit() {
        fake.senderState = "pin_required";
        fake.streams = [{device: "Living Room", state: "pin_required", credentialKind: "pin", hasAudio: true, muted: false}];
        var input = findChild(menu, "mirroringCredential");
        tryCompare(input, "visible", true);
        input.forceActiveFocus(); input.text = "0042";
        keyClick(Qt.Key_Return);
        compare(fake.credential, "0042"); compare(input.text, "");
        compare(findChild(menu, "mirroringSubmit").enabled, false);
        waitForRendering(menu);
        mouseClick(findChild(menu, "mirroringDisconnect"));
        compare(fake.disconnects, 1);
    }
    function test_receiver_toggle_name_and_incoming_code_in_both_themes() {
        for (var foreground of ["white", "#1d1d1f"]) {
            menu.foreground = foreground;
            mouseClick(findChild(menu, "mirroringReceiveTab"));
            verify(menu.receiveTab);
            waitForRendering(menu);
            var name = findChild(menu, "mirroringReceiverName");
            verify(name.enabled);
            mouseClick(findChild(menu, "mirroringReceiverToggle"));
            compare(fake.receiverDesired, true);
            fake.receiverState = "waiting";
            compare(name.enabled, false);
            fake.receiverPin = "0042";
            compare(findChild(menu, "mirroringReceiverPin").text, "0042");
            mouseClick(findChild(menu, "mirroringReceiverToggle"));
            compare(fake.receiverDesired, false);
            fake.receiverState = "off"; fake.receiverPin = "";
        }
    }
    function test_missing_backends_disable_actions_and_audio_tracks_stream() {
        fake.senderAvailable = false;
        compare(findChild(menu, "mirroringDevice").enabled, false);
        fake.receiverAvailable = false;
        mouseClick(findChild(menu, "mirroringReceiveTab"));
        compare(findChild(menu, "mirroringReceiverToggle").enabled, false);
        mouseClick(findChild(menu, "mirroringSendTab"));
        fake.senderAvailable = true; fake.senderState = "streaming";
        fake.streams = [{device: "Living Room", state: "streaming", hasAudio: true, muted: false}];
        var audio = findChild(menu, "mirroringAudio");
        verify(audio.checked);
        waitForRendering(menu);
        mouseClick(audio);
        compare(fake.audioDesired, false);
        compare(findChild(menu, "mirroringDisconnect").text, "Stop Mirroring");
        verify(menu.implicitHeight < 700);
    }
    function test_extend_stays_visible_when_niri_cannot_create_a_display() {
        mouseClick(findChild(menu, "mirroringExtend"));
        compare(fake.layout, "extend");
        compare(findChild(menu, "mirroringDevice").enabled, false);
        fake.extendAvailable = true;
        fake.extendOutput = "HDMI-A-1";
        fake.extendMethod = "dummy";
        compare(findChild(menu, "mirroringDevice").enabled, true);
        mouseClick(findChild(menu, "mirroringMirror"));
        compare(fake.layout, "mirror");
    }
}

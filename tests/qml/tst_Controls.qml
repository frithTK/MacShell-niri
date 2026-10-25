import QtQuick
import QtTest
import "../../MacShell" as Port

TestCase {
    id: test
    name: "Controls"
    when: windowShown
    width: 800; height: 800; visible: true
    QtObject {
        id: fake
        property var sample: ({cpu: 24, cores: {cpu0: 20, cpu1: 28}, memory: {used: 8589934592, total: 17179869184, swapUsed: 0}, network: [1000, 2000], disk: [3000, 4000], interface: "eth0", device: "nvme0n1", capacity: {free: 10000000000}, time: 1})
        property var history: [sample]
        property bool stale: false
        property var prompt: ({id: 1, ssid: "Test Wi-Fi", name: "Keyboard", method: "RequestConfirmation", code: "000042", entered: 0})
        property string error: ""
        property bool desired: false
        property bool available: false
        property int temperature: 4000
        property string label: "Requires wlsunset"
        property string state: "choose"
        property string output: "test"
        property string microphone: "mic"
        property string sink: "sink"
        property string audio: "none"
        property bool mixAvailable: true
        property bool busy: false
        property bool recording: false
        property bool region: false
        property string geometry: ""
        property string file: ""
        property int countdown: 3
        property var outputs: [{name: "test"}]
        property var microphones: [{name: "mic", label: "Microphone"}]
        property var sinks: [{name: "sink", label: "Speakers"}]
        property int joins: 0
        property string secret: ""
        property int starts: 0
        function gib(v) { return ((v || 0) / 1073741824).toFixed(1); }
        function rate(v) { return v === null || v === undefined ? "—" : v + "B"; }
        function join(n, password) { joins++; secret = password; }
        function cancel() { }
        function respond(accept, value) { }
        function retry() { }
        function start() { starts++; }
        function stop() { }
        function select() { }
        function prepare() { }
        function timeLabel() { return "0:00"; }
    }
    QtObject { id: modes; function label(kind) { return "Off"; } function set(kind, mode) { } }
    Component { id: statsComponent; Port.SystemStatsMenu {} }
    Component { id: joinComponent; Port.WifiJoinDialog {} }
    Component { id: nightComponent; Port.NightShiftMenu {} }
    Component { id: durationComponent; Port.DurationMenu {} }
    Component { id: pairComponent; Port.BluetoothPairDialog {} }
    Component { id: recordingComponent; Port.RecordingMenu {} }
    SignalSpy { id: backSpy; signalName: "backRequested" }
    SignalSpy { id: nightSpy; signalName: "enabledPicked" }
    function init() {
        fake.available = false; fake.region = false; fake.audio = "none";
        fake.geometry = ""; fake.busy = false; fake.state = "choose"; fake.starts = 0;
        fake.desired = false; fake.error = "";
        backSpy.target = null; backSpy.clear();
        nightSpy.target = null; nightSpy.clear();
    }
    function test_dialogs_load_in_both_themes() {
        var components = [statsComponent, joinComponent, nightComponent, durationComponent, pairComponent, recordingComponent];
        for (var c = 0; c < components.length; c++) {
            for (var theme = 0; theme < 2; theme++) {
                var item = createTemporaryObject(components[c], test, {controller: c === 3 ? modes : fake, width: 366, foreground: theme === 0 ? "#ffffff" : "#1d1d1f"});
                verify(item !== null);
                tryVerify(() => item.implicitHeight > 60, 1000, "Dialog " + c + " has no content: " + item.implicitHeight);
                verify(item.implicitHeight < 700, "Dialog is unbounded");
                if (c === 5) {
                    var combo = findChild(item, "recordMonitor");
                    combo.popup.open();
                    tryCompare(combo.popup, "visible", true);
                    compare(String(combo.palette.window), theme === 0 ? "#24252b" : "#fafafb");
                    combo.popup.close();
                }
                item.destroy(); wait(1);
            }
        }
    }
    function test_wifi_enter_submits_and_clears_secret() {
        fake.joins = 0;
        var item = createTemporaryObject(joinComponent, test, {controller: fake, width: 366});
        var password = findChild(item, "wifiPassword");
        password.forceActiveFocus(); password.text = "test password";
        keyClick(Qt.Key_Return);
        compare(fake.joins, 1); compare(fake.secret, "test password"); compare(password.text, "");
    }
    function test_missing_recorder_blocks_start() {
        fake.available = false;
        var item = createTemporaryObject(recordingComponent, test, {controller: fake, width: 366});
        compare(findChild(item, "recordStart").enabled, false);
        fake.available = true;
        compare(findChild(item, "recordStart").enabled, true);
    }
    function test_night_shift_switch_and_temperature_need_no_retry() {
        fake.available = true;
        var item = createTemporaryObject(nightComponent, test, {controller: fake, width: 366});
        nightSpy.target = item;
        tryVerify(() => item.implicitHeight > 100);
        waitForRendering(item);
        compare(findChild(item, "nightShiftRetry").visible, false);
        compare(findChild(item, "nightShiftTemperature").enabled, true);
        mouseClick(findChild(item, "nightShiftSwitch"));
        compare(nightSpy.count, 1); compare(nightSpy.signalArguments[0][0], true);
        fake.error = "Gamma control unavailable";
        compare(findChild(item, "nightShiftRetry").visible, true);
        fake.error = ""; fake.available = false;
        compare(findChild(item, "nightShiftSwitch").enabled, false);
        compare(findChild(item, "nightShiftTemperature").enabled, false);
    }
    function test_recording_source_audio_and_back_navigation() {
        fake.available = true;
        var item = createTemporaryObject(recordingComponent, test, {controller: fake, width: 366});
        backSpy.target = item;
        mouseClick(findChild(item, "recordRegion"));
        compare(fake.region, true);
        compare(findChild(item, "recordStart").enabled, false);
        fake.geometry = "0,0 640x480";
        compare(findChild(item, "recordStart").enabled, true);
        mouseClick(findChild(item, "recordWhole"));
        compare(fake.region, false);
        var audio = findChild(item, "recordAudio");
        audio.forceActiveFocus(); audio.popup.open();
        tryCompare(audio.popup, "opened", true);
        keyClick(Qt.Key_End); keyClick(Qt.Key_Return);
        compare(fake.audio, "both");
        tryCompare(audio.popup, "visible", false);
        verify(findChild(item, "recordMicrophone").visible);
        verify(findChild(item, "recordSystemAudio").visible);
        mouseClick(findChild(item, "recordStart"));
        compare(fake.starts, 1);
        mouseClick(findChild(item, "recordBack"));
        compare(backSpy.count, 1);
    }
}

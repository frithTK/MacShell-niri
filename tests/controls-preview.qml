import QtQuick
import QtQuick.Window
import "../MacShell" as Port

Window {
    id: window
    width: 1230; height: 1060; visible: true
    property bool dark: Qt.application.arguments.indexOf("--light") < 0
    readonly property color foreground: dark ? "#f7f7fa" : "#1d1d1f"
    color: dark ? "#111216" : "#e8e9ed"
    QtObject {
        id: sample
        property var sample: ({cpu: 17.2, cores: {cpu0: 18, cpu1: 15, cpu2: 21, cpu3: 14}, memory: {used: 8589934592, total: 34359738368, swapUsed: 0}, network: [428000, 72000], disk: [2400000, 120000], interface: "enp5s0", device: "nvme0n1p2", diskLabel: "Root filesystem block layer", capacity: {free: 274000000000}, temperature: 49})
        property var history: {
            var out = [];
            for (var i = 0; i <= 60; i++) out.push({time: i, cpu: 15 + Math.sin(i / 4) * 9 + (i > 30 && i < 40 ? 22 : 0), memory: {used: 8589934592 + i * 3000000, total: 34359738368}, network: [100000 + Math.abs(Math.sin(i / 5)) * 400000], disk: [Math.abs(Math.cos(i / 7)) * 2500000]});
            return out;
        }
        property bool stale: false
        function gib(v) { return ((v || 0) / 1073741824).toFixed(1); }
        function rate(v) { if (v === null || v === undefined) return "—"; return v >= 1000000 ? (v / 1000000).toFixed(1) + "M" : v >= 1000 ? (v / 1000).toFixed(0) + "K" : v + "B"; }
    }
    QtObject {
        id: recorder
        property string state: "choose"
        property bool busy: false
        property bool recording: false
        property bool available: true
        property bool mixAvailable: true
        property string output: "DP-1"
        property string microphone: "mic"
        property string sink: "speakers"
        property string audio: "both"
        property bool region: false
        property string geometry: ""
        property string error: ""
        property string file: ""
        property int countdown: 3
        property var outputs: [{name: "DP-1"}, {name: "HDMI-A-1"}]
        property var microphones: [{name: "mic", label: "USB microphone"}]
        property var sinks: [{name: "speakers", label: "Desktop speakers"}]
        function timeLabel() { return "0:00"; }
        function prepare() { }
        function start() { }
        function stop() { }
        function select() { }
    }
    QtObject {
        id: night
        property bool desired: true
        property bool available: true
        property int temperature: 4000
        property string label: "4000 K"
        property string error: ""
        function retry() { }
    }
    QtObject { id: durations; function label(kind) { return "Off"; } function set(kind, value) { } }
    QtObject {
        id: wifi
        property var prompt: ({ssid: "Home Network"})
        property string error: ""
        function join(n, password) { }
        function cancel() { }
    }
    QtObject {
        id: bluetooth
        property var prompt: ({id: 1, name: "Wireless Keyboard", method: "RequestConfirmation", code: "048291", entered: 0})
        property string error: ""
        function respond(accept, value) { }
        function cancel() { }
    }
    component Card: Rectangle {
        property alias body: loader.sourceComponent
        width: 378; height: loader.implicitHeight + 32
        radius: 18; color: window.dark ? "#24252b" : "#fafafb"
        border.color: window.dark ? "#33343c" : "#d5d6dc"
        Loader { id: loader; x: 16; y: 16; width: parent.width - 32 }
    }
    Rectangle { anchors.fill: parent; color: window.color }
    Text { x: 28; y: 24; text: "MacShell · Controls"; color: window.foreground; font {pixelSize: 26; weight: Font.DemiBold} }
    Text { x: 28; y: 63; text: "Component preview · simulated devices and measurements"; color: window.foreground; opacity: .5; font.pixelSize: 12 }
    Rectangle {
        x: 28; y: 92; width: 1174; height: 36; radius: 9; color: window.dark ? "#24252b" : "#fafafb"
        Text { x: 12; anchors.verticalCenter: parent.verticalCenter; text: "Activity in the menu bar"; color: window.foreground; font.pixelSize: 12; opacity: .7 }
        Port.SystemStatsBar { anchors.right: parent.right; anchors.rightMargin: 14; anchors.verticalCenter: parent.verticalCenter; controller: sample; foreground: window.foreground; budget: 260 }
    }
    Row {
        x: 28; y: 148; spacing: 20
        Column {
            spacing: 20
            Card { body: Component { Port.SystemStatsMenu { controller: sample; foreground: window.foreground } } }
            Card { body: Component { Port.NightShiftMenu { controller: night; foreground: window.foreground } } }
        }
        Column {
            spacing: 20
            Card { body: Component { Port.RecordingMenu { controller: recorder; foreground: window.foreground } } }
            Card { body: Component { Port.WifiJoinDialog { controller: wifi; foreground: window.foreground } } }
        }
        Column {
            spacing: 20
            Card { body: Component { Port.DurationMenu { controller: durations; foreground: window.foreground } } }
            Card { body: Component { Port.BluetoothPairDialog { controller: bluetooth; foreground: window.foreground } } }
        }
    }
    Timer {
        interval: 600; running: true
        onTriggered: window.contentItem.grabToImage(result => {
            var path = window.dark ? "/tmp/macshell-controls-dark.png" : "/tmp/macshell-controls-light.png";
            result.saveToFile(path); Qt.quit();
        })
    }
}

import QtQuick
import QtQuick.Window
import "../MacShell" as Port

Window {
    id: window
    width: 812; height: 550; visible: true
    property bool dark: Qt.application.arguments.indexOf("--light") < 0
    color: dark ? "#111216" : "#e8e9ed"
    Rectangle { anchors.fill: parent; color: window.color }
    QtObject {
        id: demo
        property bool senderAvailable: true
        property bool receiverAvailable: true
        property string senderState: "ready"
        property string receiverState: "waiting"
        property string senderError: ""
        property string receiverError: ""
        property string error: ""
        property string receiverName: "MacShell"
        property string advertisedName: "MacShell"
        property string receiverPin: "0042"
        property string receiverClient: "iPhone"
        property bool scanning: false
        property var devices: [{key: "living-room", name: "Living Room · Apple TV"}, {key: "office", name: "Office · Mac"}]
        property var streams: []
        property var pending: null
        property bool sending: false
        property bool connecting: false
        property bool receiving: true
        function refresh() { }
        function connectDevice(key) { }
        function submitCredential(value) { }
        function disconnect() { }
        function setReceiver(enabled) { }
        function setAudio(enabled) { }
    }
    Text {
        x: 24; y: 22; text: "Screen Mirroring · AirPlay"
        color: window.dark ? "#f7f7fa" : "#1d1d1f"
        font { family: "Inter Variable"; pixelSize: 24; weight: Font.DemiBold }
    }
    Repeater {
        model: 2
        delegate: Rectangle {
            required property int index
            x: 24 + index * 394; y: 76; width: 370; height: menu.implicitHeight + 28
            radius: 22; color: window.dark ? "#292a30" : "#fafafb"
            Port.ScreenMirroringMenu {
                id: menu; x: 14; y: 14; width: parent.width - 28
                controller: demo; receiveTab: index === 1
                foreground: window.dark ? "#f7f7fa" : "#1d1d1f"
            }
        }
    }
    Timer {
        interval: 600; running: true
        onTriggered: {
            var option = Qt.application.arguments.find(a => a.indexOf("--capture=") === 0);
            if (option) window.contentItem.grabToImage(result => { result.saveToFile(option.substring(10)); Qt.quit(); });
        }
    }
}

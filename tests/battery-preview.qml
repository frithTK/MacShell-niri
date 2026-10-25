import QtQuick
import QtQuick.Window
import "../MacShell" as Port

Window {
    id: window
    width: 430; height: 650; visible: true
    property bool dark: true
    readonly property color foreground: dark ? "#f7f7fa" : "#1d1d1f"
    color: dark ? "#111216" : "#e8e9ed"
    Rectangle { anchors.fill: parent; color: window.color }
    QtObject {
        id: battery
        property bool present: true
        property int percentage: 72
        property bool charging: false
        property bool full: false
        property bool onBattery: true
        property string remaining: "About 3 h 42 min remaining"
        property string source: "Power Source: Battery"
    }
    QtObject {
        id: power
        property bool available: true
        property bool busy: false
        property bool gameHold: false
        property string profile: "balanced"
        property var profiles: ["power-saver", "balanced", "performance"]
        property string inhibited: ""
        property string degraded: ""
        property string error: ""
        function label(v) { return ({"power-saver": "Low Power", balanced: "Balanced", performance: "Performance"})[v]; }
        function supported(v) { return profiles.indexOf(v) >= 0; }
        function select(v) { profile = v; }
    }
    Text { x: 24; y: 24; text: "Battery & Energy"; color: window.foreground; font { pixelSize: 25; weight: Font.DemiBold } }
    Text { x: 24; y: 62; text: "Preview · simulated battery and system profiles"; color: window.foreground; opacity: .55; font.pixelSize: 11 }
    Rectangle {
        x: 20; y: 98; width: 390; height: menu.implicitHeight + 32
        radius: 22; color: window.dark ? "#24252b" : "#fafafb"
        border.color: window.dark ? "#33343c" : "#d5d6dc"
        Port.BatteryMenu { id: menu; x: 16; y: 16; width: parent.width - 32; battery: battery; power: power; foreground: window.foreground }
    }
    Timer {
        interval: 650; running: true
        onTriggered: window.contentItem.grabToImage(result => {
            result.saveToFile("/tmp/macshell-battery-" + (window.dark ? "dark" : "light") + ".png"); Qt.quit();
        })
    }
}

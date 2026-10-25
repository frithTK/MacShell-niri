import QtQuick
import QtQuick.Window
import "../MacShell" as Port

Window {
    id: window
    width: 430; height: 510; visible: true
    property bool dark: Qt.application.arguments.indexOf("--light") < 0
    color: dark ? "#111216" : "#e8e9ed"
    Rectangle { anchors.fill: parent; color: window.color }
    Text {
        x: 32; y: 24; text: "Keyboard controls"
        font.family: "Inter Variable"; font.pixelSize: 23; font.weight: Font.DemiBold
        color: window.dark ? "#f7f7fa" : "#1d1d1f"
    }
    Rectangle {
        x: 65; y: 80; width: 300; height: 64; radius: 18
        color: window.dark ? "#292a30" : "#fafafb"
        Text {
            x: 14; y: 8; text: "Output · 125%"
            font.family: "Inter Variable"; font.pixelSize: 12
            color: window.dark ? "#f7f7fa" : "#1d1d1f"
        }
        Port.LevelSlider {
            x: 6; y: 30; width: parent.width - 12
            maximumValue: 1.5; value: 1.25
            leftKind: "speaker"; rightKind: "speaker"; leftLevel: 3
            t: ({fg: window.dark ? "#f7f7fa" : "#1d1d1f", fg2: "#8e8e93", track: window.dark ? "#55565d" : "#d5d6dc"})
        }
    }
    Column {
        x: 65; y: 166; spacing: 22
        Repeater {
            model: [
                {kind: "volume", value: 1.5, muted: false},
                {kind: "brightness", value: .8, muted: false},
                {kind: "volume", value: 1.25, muted: true}
            ]
            Rectangle {
                required property var modelData
                width: 300; height: 76; radius: 24
                color: window.dark ? "#292a30" : "#fafafb"
                border.color: window.dark ? "#4a4b53" : "white"
                Port.LevelOsd {
                    anchors.fill: parent
                    kind: parent.modelData.kind; value: parent.modelData.value; muted: parent.modelData.muted
                    foreground: window.dark ? "#f7f7fa" : "#1d1d1f"
                }
            }
        }
    }
    Timer {
        interval: 650; running: true
        onTriggered: window.contentItem.grabToImage(result => {
            result.saveToFile("/tmp/macshell-osd-" + (window.dark ? "dark" : "light") + ".png"); Qt.quit();
        })
    }
}

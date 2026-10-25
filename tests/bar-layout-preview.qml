import QtQuick
import QtQuick.Window
import QtQuick.Controls
import Quickshell
import "../MacShell" as Port

ShellRoot {
    Port.BarPreferences { id: preferences; outputs: [{name: "DP-1", make: "Demo", model: "Display", serial: "demo", logicalRect: {x: 0, y: 0, width: 1920, height: 1080}, scale: 1}] }
    Window {
        id: window
        readonly property bool dark: Quickshell.env("MACSHELL_PREVIEW_LIGHT") !== "1"
        width: 580; height: 490; visible: true
        color: dark ? "#1e1e1e" : "#f5f5f7"
        Rectangle { anchors.fill: parent; color: window.color }
        ScrollView {
            anchors.fill: parent; anchors.margins: 24
            contentWidth: availableWidth
            Port.BarLayoutEditor { id: editor; width: parent.width; controller: preferences; foreground: window.dark ? "#f5f5f7" : "#1d1d1f" }
        }
        Timer {
            interval: 700; running: preferences.ready
            onTriggered: window.contentItem.grabToImage(result => {
                result.saveToFile(Quickshell.env("MACSHELL_PREVIEW_CAPTURE") || "/tmp/macshell-bar-layout-preview.png"); Qt.quit();
            })
        }
    }
}

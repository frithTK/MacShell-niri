import QtQuick
import QtQuick.Window
import Quickshell
import "." as Port
import "BatteriesData.js" as Data

ShellRoot {
    Window {
        id: window
        readonly property bool dark: Quickshell.env("MACSHELL_PREVIEW_LIGHT") !== "1"
        width: 1050; height: 900; visible: true; color: dark ? "#202128" : "#f0f1f5"
        Rectangle { anchors.fill: parent; color: window.color }
        Text { x: 24; y: 16; text: "Batteries · Automatic"; color: window.dark ? "white" : "#202025"; font.pixelSize: 20 }
        Row {
            x: 24; y: 54; spacing: 24
            Repeater {
                model: ["small", "medium", "large"]
                Port.WidgetPreview { required property string modelData; widgetType: "batteries"; widgetSize: modelData; widgetStyle: "normal"; dark: window.dark }
            }
        }
        Text { x: 24; y: 462; text: "Batteries · Selected devices"; color: window.dark ? "white" : "#202025"; font.pixelSize: 20 }
        Row {
            x: 24; y: 500; spacing: 24
            Repeater {
                model: ["small", "medium", "large"]
                Port.BatteriesWidget {
                    required property string modelData
                    size: modelData; style: "liquid"; darkGlass: window.dark; preview: true
                    entries: Data.demoEntries().map(row => row.kind === "headphones" ? Object.assign({}, row, {connected: false, status: "disconnected", percentage: -1}) : row)
                    settings: ({mode: "selected", devices: ["bluetooth:AA:00:00:00:00:02", "bluetooth:AA:00:00:00:00:01", "laptop",
                        "bluetooth:AA:00:00:00:00:04", "bluetooth:AA:00:00:00:00:03", "bluetooth:AA:00:00:00:00:05"]})
                }
            }
        }
        Timer {
            interval: 650; running: true
            onTriggered: window.contentItem.grabToImage(result => {
                if (!result.saveToFile(Quickshell.env("MACSHELL_PREVIEW_CAPTURE"))) Qt.exit(1); else Qt.quit();
            })
        }
    }
}

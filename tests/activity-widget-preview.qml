import QtQuick
import QtQuick.Window
import Quickshell
import "." as Port

ShellRoot {
    Window {
        id: window
        readonly property bool dark: Quickshell.env("MACSHELL_PREVIEW_LIGHT") !== "1"
        width: 1050; height: 900; visible: true; color: dark ? "#202128" : "#f0f1f5"
        Rectangle { anchors.fill: parent; color: window.color }
        Text { x: 24; y: 16; text: "Activity · Rings"; color: window.dark ? "white" : "#202025"; font.pixelSize: 20 }
        Row {
            x: 24; y: 54; spacing: 24
            Repeater {
                model: ["small", "medium", "large"]
                Port.WidgetPreview { required property string modelData; widgetType: "activity"; widgetSize: modelData; widgetStyle: "normal"; dark: window.dark }
            }
        }
        Text { x: 24; y: 462; text: "Activity · Graphs"; color: window.dark ? "white" : "#202025"; font.pixelSize: 20 }
        Row {
            x: 24; y: 500; spacing: 24
            Repeater {
                model: ["small", "medium", "large"]
                Port.WidgetPreview { required property string modelData; widgetType: "activity"; widgetSize: modelData; widgetStyle: "liquid"; dark: window.dark; activity: ({view: "graphs"}) }
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

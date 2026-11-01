import QtQuick
import QtQuick.Window
import Quickshell
import "." as Port
import "Locale" as Language

ShellRoot {
    Component.onCompleted: if (Quickshell.env("MACSHELL_PREVIEW_RUSSIAN") === "1") Language.I18n.language = "ru"
    Window {
        id: window
        readonly property bool dark: Quickshell.env("MACSHELL_PREVIEW_LIGHT") !== "1"
        width: 1050; height: 440; visible: true; color: dark ? "#202128" : "#f0f1f5"
        Rectangle { anchors.fill: parent; color: window.color }
        Text { x: 24; y: 16; text: Quickshell.env("MACSHELL_PREVIEW_RUSSIAN") === "1" ? "Таймер · S / M / L" : "Timer · Small / Medium / Large"; color: window.dark ? "white" : "#202025"; font.pixelSize: 20 }
        Row {
            x: 24; y: 54; spacing: 24
            Repeater {
                model: ["small", "medium", "large"]
                Port.WidgetPreview { required property string modelData; widgetType: "timer"; widgetSize: modelData; widgetStyle: "normal"; dark: window.dark }
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

import QtQuick
import QtQuick.Window
import Quickshell
import "../MacShell" as Port

ShellRoot {
    Port.ActivityPreferences { id: preferences }
    Window {
        id: window
        readonly property bool dark: Quickshell.env("MACSHELL_PREVIEW_LIGHT") !== "1"
        width: 700; height: Math.ceil(editor.implicitHeight + 48)
        visible: true
        color: dark ? "#1e1e1e" : "#f5f5f7"
        Rectangle { anchors.fill: parent; color: window.color }
        Port.ActivityPreferencesEditor {
            id: editor
            x: 24; y: 24; width: window.width - 48
            controller: preferences
            foreground: window.dark ? "#f5f5f7" : "#1d1d1f"
            advanced: Quickshell.env("MACSHELL_PREVIEW_ADVANCED") === "1"
        }
        Timer {
            interval: 700; running: preferences.ready
            onTriggered: window.contentItem.grabToImage(result => {
                var target = Quickshell.env("MACSHELL_PREVIEW_CAPTURE");
                result.saveToFile(target || "/tmp/macshell-activity-settings-" + (window.dark ? "dark" : "light") + ".png");
                Qt.quit();
            })
        }
    }
}

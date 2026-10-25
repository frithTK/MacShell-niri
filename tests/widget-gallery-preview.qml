import QtQuick
import QtQuick.Window
import QtQuick.Controls
import Quickshell
import "../MacShell" as Port

ShellRoot {
    QtObject {
        id: demo
        property bool ready: true
        property bool editable: !readOnly
        property bool settingsEditable: !readOnly
        property bool readOnly: Quickshell.env("MACSHELL_PREVIEW_RECOVERY") === "1"
        property bool pending: false
        property bool canRecover: readOnly
        property string error: ""
        property string notice: readOnly ? "Some saved widget records are invalid. Restore a backup or reset widgets; the original file will be kept." : ""
        property bool editing: false
        property int rev: 0
        property string screenName: "eDP-1"
        property var displayChoices: Quickshell.env("MACSHELL_PREVIEW_DISPLAYS") === "1" ? [{name: "eDP-1", label: "eDP-1"}, {name: "DP-1", label: "DP-1"}] : [{name: "eDP-1", label: "eDP-1"}]
        property var unavailableWidgets: []
        property var undoStack: []
        property bool canUndoDelete: false
        property var instanceRows: [
            {id: "demo-weather", type: "weather", label: "Weather", supported: true, size: "small", style: "liquid", mode: "auto", outputName: "eDP-1", display: "eDP-1", placed: true, canPlace: true, reason: ""},
            {id: "demo-calendar", type: "calendar", label: "Calendar", supported: true, size: "medium", style: "normal", mode: "auto", outputName: "eDP-1", display: "eDP-1", placed: true, canPlace: true, reason: ""},
            {id: "demo-player", type: "player", label: "Player", supported: true, size: "large", style: "liquid", mode: "auto", outputName: "", display: "HDMI-A-1", placed: false, canPlace: false, reason: "Display disconnected or ambiguous"}
        ]
        property var unplacedWidgets: Quickshell.env("MACSHELL_PREVIEW_DISPLAYS") === "1" ? [{id: "demo", type: "player", display: "HDMI-A-1", reason: "Display disconnected or ambiguous"}] : []
        property string tempUnit: "C"
        property string locMode: "auto"
        property string cityName: ""
        function setWeather(key, value) { demo[key] = value; }
        function count(type) { return 0; }
        function addWidget(type, style, size) { return true; }
    }
    Window {
        id: window
        readonly property bool dark: Quickshell.env("MACSHELL_PREVIEW_LIGHT") !== "1"
        readonly property bool editorOnly: Quickshell.env("MACSHELL_PREVIEW_EDITOR") === "1"
        readonly property bool appearanceOnly: Quickshell.env("MACSHELL_PREVIEW_APPEARANCE") === "1"
        width: 580; height: appearanceOnly ? 840 : demo.readOnly ? 860 : 720; visible: !editorOnly
        color: dark ? "#1e1e1e" : "#f5f5f7"
        Rectangle { anchors.fill: parent; color: window.color }
        ScrollView {
            anchors.fill: parent; anchors.margins: 24; contentWidth: availableWidth
            Port.WidgetGallery {
                visible: !window.appearanceOnly
                width: parent.width; controller: demo; confirmRecovery: demo.readOnly
                adding: Quickshell.env("MACSHELL_PREVIEW_ADD") === "1"
                focusInstanceId: Quickshell.env("MACSHELL_PREVIEW_DISPLAYS") === "1" ? "demo-player" : ""
                foreground: window.dark ? "#f5f5f7" : "#1d1d1f"
            }
        }
        Port.WidgetAppearanceEditor {
            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 24
            visible: window.appearanceOnly; controller: demo
            foreground: window.dark ? "#f5f5f7" : "#1d1d1f"
            record: ({id: "demo-player", type: "player", size: "medium", style: "liquid", defaultStyle: "liquid", mode: "auto", supported: true,
                savedSettings: {style: "liquid", appearance: {fontFamily: "Noto Sans", textScale: 1.2, density: "comfortable", tint: "#3d907b"}}})
        }
        Timer {
            interval: 700; running: true
            onTriggered: (window.editorOnly ? editSample.contentItem : window.contentItem).grabToImage(result => {
                result.saveToFile(Quickshell.env("MACSHELL_PREVIEW_CAPTURE")); Qt.quit();
            })
        }
    }
    Port.WidgetEditWindow {
        id: editSample
        visible: window.editorOnly
        foreground: window.dark ? "#f5f5f7" : "#1d1d1f"
        selectedId: "demo-player"; selectedType: "player"; selectedSize: "medium"
        canConfigure: true; canUndo: true
        displayChoices: [{name: "eDP-1", label: "eDP-1"}, {name: "DP-1", label: "DP-1"}]; selectedOutput: "eDP-1"
    }
}

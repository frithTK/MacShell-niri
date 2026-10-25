import QtQuick
import QtQuick.Controls

ControlMenu {
    id: root
    required property var controller
    property string kind: "focus"
    contentItem: Column {
        spacing: 8
        ControlHeader { width: parent.width; title: root.kind === "focus" ? "Focus" : "Keep Awake"; foreground: root.foreground; family: root.font.family; onBackRequested: root.backRequested() }
        Text { font.family: root.font.family; width: parent.width; text: root.controller.label(root.kind); color: root.foreground; opacity: .6; wrapMode: Text.Wrap }
        Repeater {
            model: [{mode: "15", label: "For 15 minutes"}, {mode: "30", label: "For 30 minutes"}, {mode: "60", label: "For one hour"}, {mode: "evening", label: new Date().getHours() >= 20 ? "Until tomorrow at 20:00" : "Until today at 20:00"}, {mode: "manual", label: "Until turned off"}, {mode: "off", label: "Turn off"}]
            delegate: ControlChoice {
                required property var modelData
                width: root.width; text: modelData.label
                selected: !!(root.controller.values && root.controller.values[root.kind] && root.controller.values[root.kind].mode === modelData.mode)
                onClicked: root.controller.set(root.kind, modelData.mode)
            }
        }
        Text { font.family: root.font.family; visible: root.kind === "awake"; width: parent.width; wrapMode: Text.Wrap; text: "Prevents automatic idle while this session is running. Lock and Suspend remain available."; color: root.foreground; opacity: .6; font.pixelSize: 11 }
    }
}

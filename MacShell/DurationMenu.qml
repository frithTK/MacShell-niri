import QtQuick
import "Locale" as Language
import QtQuick.Controls

ControlMenu {
    id: root
    required property var controller
    property string kind: "focus"
    contentItem: Column {
        spacing: 8
        ControlHeader { width: parent.width; title: root.kind === "focus" ? Language.I18n.text("ui.t_9d3cab2b5efe") : Language.I18n.text("ui.t_7ace19020244"); foreground: root.foreground; family: root.font.family; onBackRequested: root.backRequested() }
        Text { font.family: root.font.family; width: parent.width; text: root.controller.label(root.kind); color: root.foreground; opacity: .6; wrapMode: Text.Wrap }
        Repeater {
            model: [{mode: "15", label: Language.I18n.text("ui.t_a5db9207d504")}, {mode: "30", label: Language.I18n.text("ui.t_3a96d51f16ad")}, {mode: "60", label: Language.I18n.text("ui.t_2f175d587b4b")}, {mode: "evening", label: new Date().getHours() >= 20 ? Language.I18n.text("ui.t_2fdb56fa27fb") : Language.I18n.text("ui.t_af39ae50d787")}, {mode: "manual", label: Language.I18n.text("ui.t_53e7119012bc")}, {mode: "off", label: Language.I18n.text("ui.t_06f0e210b27d")}]
            delegate: ControlChoice {
                required property var modelData
                width: root.width; text: modelData.label
                selected: !!(root.controller.values && root.controller.values[root.kind] && root.controller.values[root.kind].mode === modelData.mode)
                onClicked: root.controller.set(root.kind, modelData.mode)
            }
        }
        Text { font.family: root.font.family; visible: root.kind === "awake"; width: parent.width; wrapMode: Text.Wrap; text: Language.I18n.text("ui.t_59ffdebafce3"); color: root.foreground; opacity: .6; font.pixelSize: 11 }
    }
}

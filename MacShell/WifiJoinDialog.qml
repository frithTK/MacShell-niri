import QtQuick
import "Locale" as Language
import QtQuick.Controls

ControlMenu {
    id: root
    required property var controller
    readonly property var network: controller.prompt
    contentItem: Column {
        spacing: 12
        ControlHeader { width: parent.width; title: Language.I18n.text("ui.t_24e35b22bdbd") + (root.network ? root.network.ssid : "") + "”"; foreground: root.foreground; family: root.font.family; backVisible: false }
        Text { font.family: root.font.family; width: parent.width; wrapMode: Text.Wrap; text: Language.I18n.text("ui.t_ea3d6545123d"); color: root.foreground; opacity: .6; font.pixelSize: 12 }
        ControlTextField { id: password; objectName: "wifiPassword"; width: parent.width; placeholderText: Language.I18n.text("ui.t_e7cf3ef4f17c"); echoMode: show.checked ? TextInput.Normal : TextInput.Password; focus: true; onAccepted: submit.clicked(); Component.onCompleted: forceActiveFocus() }
        ControlCheckBox { id: show; text: Language.I18n.text("ui.t_6aeaa6a53d09") }
        Text { font.family: root.font.family; width: parent.width; wrapMode: Text.Wrap; color: "#ff695e"; text: Language.I18n.legacy(root.controller.error); visible: text !== "" }
        Row {
        spacing: 8
            ControlButton { text: Language.I18n.text("common.cancel"); onClicked: root.controller.cancel() }
            ControlButton { id: submit; objectName: "wifiJoin"; primary: true; text: Language.I18n.text("ui.t_fd30fe681b4b"); enabled: password.text.length > 0; onClicked: { if (password.text.length > 0 && root.network) { var secret = password.text; password.clear(); root.controller.join(root.network, secret); } } }
        }
        Component.onDestruction: password.clear()
    }
}

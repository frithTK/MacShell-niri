import QtQuick
import QtQuick.Controls

ControlMenu {
    id: root
    required property var controller
    readonly property var network: controller.prompt
    contentItem: Column {
        spacing: 12
        ControlHeader { width: parent.width; title: "Join “" + (root.network ? root.network.ssid : "") + "”"; foreground: root.foreground; family: root.font.family; backVisible: false }
        Text { font.family: root.font.family; width: parent.width; wrapMode: Text.Wrap; text: "Enter the network password. NetworkManager stores it in your connection profile."; color: root.foreground; opacity: .6; font.pixelSize: 12 }
        ControlTextField { id: password; objectName: "wifiPassword"; width: parent.width; placeholderText: "Password"; echoMode: show.checked ? TextInput.Normal : TextInput.Password; focus: true; onAccepted: submit.clicked(); Component.onCompleted: forceActiveFocus() }
        ControlCheckBox { id: show; text: "Show password" }
        Text { font.family: root.font.family; width: parent.width; wrapMode: Text.Wrap; color: "#ff695e"; text: root.controller.error; visible: text !== "" }
        Row {
        spacing: 8
            ControlButton { text: "Cancel"; onClicked: root.controller.cancel() }
            ControlButton { id: submit; objectName: "wifiJoin"; primary: true; text: "Join"; enabled: password.text.length > 0; onClicked: { if (password.text.length > 0 && root.network) { var secret = password.text; password.clear(); root.controller.join(root.network, secret); } } }
        }
        Component.onDestruction: password.clear()
    }
}

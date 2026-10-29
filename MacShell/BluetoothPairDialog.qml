import QtQuick
import "Locale" as Language
import QtQuick.Controls

ControlMenu {
    id: root
    required property var controller
    property int renderedPrompt: -1
    Component.onCompleted: renderedPrompt = prompt ? prompt.id : -1
    readonly property var prompt: controller.prompt
    readonly property string method: prompt ? prompt.method : ""
    readonly property bool entry: method === "RequestPinCode" || method === "RequestPasskey"
    readonly property bool display: method === "DisplayPasskey" || method === "DisplayPinCode"
    contentItem: Column {
        spacing: 12
        ControlHeader { width: parent.width; title: Language.I18n.text("ui.t_9c289bfbd5f8") + (root.prompt ? root.prompt.name : "") + "”"; foreground: root.foreground; family: root.font.family; backVisible: false }
        Text { font.family: root.font.family; width: parent.width; wrapMode: Text.Wrap; color: root.foreground; text: root.entry ? Language.I18n.text("ui.t_4df675a1cc3c") : root.display ? Language.I18n.text("ui.t_43f4ef3b0543") : root.method === "RequestConfirmation" ? Language.I18n.text("ui.t_b87192c645ca") : Language.I18n.text("ui.t_e0a40626c894") }
        Text { visible: !root.entry && text !== ""; text: root.prompt ? root.prompt.code : ""; color: root.foreground; font {family: "monospace"; pixelSize: 32; bold: true} }
        Text { font.family: root.font.family; visible: root.method === "DisplayPasskey"; text: root.prompt ? root.prompt.entered + Language.I18n.text("ui.t_7c14fd9d19c7") : ""; color: root.foreground; opacity: .6 }
        ControlTextField { id: code; objectName: "bluetoothCode"; visible: root.entry; width: parent.width; placeholderText: Language.I18n.text("ui.t_eef3e5b4d8f6"); maximumLength: root.method === "RequestPasskey" ? 6 : 16; onAccepted: root.controller.respond(true, text, root.renderedPrompt); Component.onCompleted: if (visible) forceActiveFocus() }
        Text { font.family: root.font.family; visible: text !== ""; text: Language.I18n.legacy(root.controller.error); color: "#ff695e"; width: parent.width; wrapMode: Text.Wrap }
        Row { spacing: 8; ControlButton { text: Language.I18n.text("common.cancel"); onClicked: root.controller.cancel() } ControlButton { visible: !root.display; text: Language.I18n.text("ui.t_eebdd24a77d9"); primary: true; enabled: !root.entry || code.text.length > 0; onClicked: root.controller.respond(true, code.text, root.renderedPrompt) } }
    }
}

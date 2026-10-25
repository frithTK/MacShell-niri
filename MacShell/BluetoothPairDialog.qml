import QtQuick
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
        ControlHeader { width: parent.width; title: "Pair “" + (root.prompt ? root.prompt.name : "") + "”"; foreground: root.foreground; family: root.font.family; backVisible: false }
        Text { font.family: root.font.family; width: parent.width; wrapMode: Text.Wrap; color: root.foreground; text: root.entry ? "Enter the code provided by the device." : root.display ? "Type this code on the device, then press Enter." : root.method === "RequestConfirmation" ? "Confirm that the same code appears on the device." : "Allow this device to pair and use its services?" }
        Text { visible: !root.entry && text !== ""; text: root.prompt ? root.prompt.code : ""; color: root.foreground; font {family: "monospace"; pixelSize: 32; bold: true} }
        Text { font.family: root.font.family; visible: root.method === "DisplayPasskey"; text: root.prompt ? root.prompt.entered + " of 6 digits entered" : ""; color: root.foreground; opacity: .6 }
        ControlTextField { id: code; objectName: "bluetoothCode"; visible: root.entry; width: parent.width; placeholderText: "PIN / passkey"; maximumLength: root.method === "RequestPasskey" ? 6 : 16; onAccepted: root.controller.respond(true, text, root.renderedPrompt); Component.onCompleted: if (visible) forceActiveFocus() }
        Text { font.family: root.font.family; visible: text !== ""; text: root.controller.error; color: "#ff695e"; width: parent.width; wrapMode: Text.Wrap }
        Row { spacing: 8; ControlButton { text: "Cancel"; onClicked: root.controller.cancel() } ControlButton { visible: !root.display; text: "Confirm"; primary: true; enabled: !root.entry || code.text.length > 0; onClicked: root.controller.respond(true, code.text, root.renderedPrompt) } }
    }
}

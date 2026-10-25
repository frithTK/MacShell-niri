import QtQuick
import QtQuick.Controls

ControlMenu {
    id: root
    required property var controller
    property bool receiveTab: controller.receiverPin !== ""
    Connections {
        target: root.controller
        function onReceiverPinChanged() { if (root.controller.receiverPin !== "") root.receiveTab = true; }
        function onPendingChanged() { if (root.controller.pending) root.receiveTab = false; }
    }
    contentItem: Column {
        spacing: 12
        ControlHeader { width: parent.width; title: "Screen Mirroring"; foreground: root.foreground; family: root.font.family; onBackRequested: root.backRequested() }
        Row {
            width: parent.width; spacing: 6
            ControlChoice { objectName: "mirroringSendTab"; width: (parent.width - 6) / 2; text: "Send Screen"; selected: !root.receiveTab; onClicked: root.receiveTab = false }
            ControlChoice { objectName: "mirroringReceiveTab"; width: (parent.width - 6) / 2; text: "Receive AirPlay"; selected: root.receiveTab; onClicked: root.receiveTab = true }
        }
        Rectangle { width: parent.width; height: 1; color: root.separator }
        Column {
            width: parent.width; spacing: 10; visible: !root.receiveTab
            Text {
                width: parent.width; wrapMode: Text.Wrap; color: root.secondary; font: root.font
                text: !root.controller.senderAvailable ? "Install Doubletake to send this screen to an Apple TV, Mac or compatible TV."
                      : root.controller.sending ? "Your screen is being mirrored."
                      : root.controller.pending ? "Enter the code shown on the display, or its configured AirPlay password."
                      : root.controller.connecting ? "Connecting… Choose a screen or window in the system dialog when asked."
                      : "Choose an AirPlay display on the same network."
            }
            Column {
                width: parent.width; spacing: 6
                Repeater {
                    model: root.controller.streams
                    delegate: Rectangle {
                        required property var modelData
                        width: parent.width; height: activeStream.height + 20; radius: 12
                        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, .06)
                        Column {
                            id: activeStream; x: 10; y: 10; width: parent.width - 20; spacing: 8
                            Text { width: parent.width; text: modelData.device; elide: Text.ElideRight; color: root.foreground; font: root.font }
                            Text { width: parent.width; text: ({streaming: "Mirroring", pin_required: modelData.credentialKind === "password" ? "Password required" : "Code required", connecting: "Connecting…"})[modelData.state] || modelData.state; color: root.secondary; font.pixelSize: 12 }
                            ControlCheckBox {
                                objectName: "mirroringAudio"; text: "Send system audio"; visible: modelData.state === "streaming"
                                enabled: modelData.hasAudio; checked: modelData.hasAudio && !modelData.muted
                                onToggled: root.controller.setAudio(checked)
                            }
                        }
                    }
                }
            }
            Column {
                width: parent.width; spacing: 8; visible: root.controller.pending !== null
                ControlTextField {
                    id: credential; objectName: "mirroringCredential"; width: parent.width
                    echoMode: TextInput.Password; maximumLength: 128
                    placeholderText: root.controller.pending && root.controller.pending.credentialKind === "password" ? "AirPlay password" : "Code on the display"
                    Accessible.name: placeholderText
                    onAccepted: if (text.length > 0) { root.controller.submitCredential(text); clear(); }
                    onVisibleChanged: { clear(); if (visible) Qt.callLater(() => credential.forceActiveFocus()); }
                }
                ControlButton { objectName: "mirroringSubmit"; width: parent.width; primary: true; text: "Connect"; enabled: credential.text.length > 0; onClicked: { root.controller.submitCredential(credential.text); credential.clear(); } }
            }
            ControlButton {
                objectName: "mirroringDisconnect"; width: parent.width
                visible: root.controller.streams.length > 0 || root.controller.connecting
                text: root.controller.sending ? "Stop Mirroring" : "Cancel Connection"
                onClicked: root.controller.disconnect()
            }
            Column {
                width: parent.width; spacing: 6; visible: !root.controller.sending && !root.controller.connecting
                Repeater {
                    model: root.controller.devices
                    delegate: ControlButton {
                        required property var modelData
                        objectName: "mirroringDevice"; width: parent.width
                        text: modelData.name; enabled: root.controller.senderAvailable
                        onClicked: root.controller.connectDevice(modelData.key)
                    }
                }
                Text {
                    width: parent.width; wrapMode: Text.Wrap; color: root.secondary; font.pixelSize: 12
                    visible: root.controller.senderAvailable && root.controller.devices.length === 0
                    text: root.controller.scanning ? "Searching for AirPlay displays…" : "No displays found. Check that AirPlay is enabled on the receiving device."
                }
                ControlButton { objectName: "mirroringRefresh"; width: parent.width; text: root.controller.scanning ? "Searching…" : "Search Again"; enabled: root.controller.senderAvailable && !root.controller.scanning; onClicked: root.controller.refresh() }
            }
            Text { width: parent.width; visible: text !== ""; text: root.controller.senderError; wrapMode: Text.Wrap; color: root.warning; font.pixelSize: 12 }
        }
        Column {
            width: parent.width; spacing: 12; visible: root.receiveTab
            Text {
                width: parent.width; wrapMode: Text.Wrap; color: root.secondary; font: root.font
                text: !root.controller.receiverAvailable ? "Install UxPlay to show an iPhone, iPad or Mac screen on this computer."
                      : root.controller.receiverState === "streaming" ? "Receiving " + (root.controller.receiverClient || "AirPlay") + ". The picture opens in its own window."
                      : root.controller.receiverState === "starting" ? "Starting AirPlay receiver…"
                      : root.controller.receiving ? "On your iPhone, iPad or Mac, open Screen Mirroring and choose “" + root.controller.advertisedName + "”."
                      : "Make this computer available as an AirPlay display."
            }
            ControlTextField {
                objectName: "mirroringReceiverName"; width: parent.width; maximumLength: 40
                text: root.controller.receiverName; placeholderText: "AirPlay name"
                Accessible.name: "Name shown on Apple devices"
                enabled: !root.controller.receiving
                onTextEdited: root.controller.receiverName = text
            }
            Rectangle {
                width: parent.width; height: 78; radius: 12; visible: root.controller.receiverPin !== ""
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, .06)
                Column {
                    anchors.centerIn: parent; spacing: 4
                    Text { text: "Enter this code on your Apple device"; color: root.secondary; font.pixelSize: 11; anchors.horizontalCenter: parent.horizontalCenter }
                    Text {
                        objectName: "mirroringReceiverPin"; text: root.controller.receiverPin; color: root.foreground
                        font { family: root.font.family; pixelSize: 28; weight: Font.DemiBold; letterSpacing: 5 }
                        anchors.horizontalCenter: parent.horizontalCenter
                    }
                }
            }
            ControlButton {
                objectName: "mirroringReceiverToggle"; width: parent.width; primary: !root.controller.receiving
                enabled: root.controller.receiverAvailable && (root.controller.receiving || root.controller.receiverName.trim() !== "")
                text: root.controller.receiving ? "Stop AirPlay Receiver" : "Enable AirPlay Receiver"
                onClicked: root.controller.setReceiver(!root.controller.receiving)
            }
            Text { width: parent.width; visible: text !== ""; text: root.controller.receiverError; wrapMode: Text.Wrap; color: root.warning; font.pixelSize: 12 }
            Text { width: parent.width; wrapMode: Text.Wrap; color: root.secondary; font.pixelSize: 11; text: "Both devices need the same local network. The receiver stops when you turn it off or exit MacShell." }
        }
        Text { width: parent.width; visible: text !== ""; text: root.controller.error; wrapMode: Text.Wrap; color: root.warning; font.pixelSize: 12 }
    }
}

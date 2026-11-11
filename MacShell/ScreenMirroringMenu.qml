import QtQuick
import "Locale" as Language
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
        ControlHeader { width: parent.width; title: Language.I18n.text("ui.t_a72c5d7ed939"); foreground: root.foreground; family: root.font.family; onBackRequested: root.backRequested() }
        Row {
            width: parent.width; spacing: 6
            ControlChoice { objectName: "mirroringSendTab"; width: (parent.width - 6) / 2; text: Language.I18n.text("ui.t_7a900b5e72f7"); selected: !root.receiveTab; onClicked: root.receiveTab = false }
            ControlChoice { objectName: "mirroringReceiveTab"; width: (parent.width - 6) / 2; text: Language.I18n.text("ui.t_b853ae2696ab"); selected: root.receiveTab; onClicked: root.receiveTab = true }
        }
        Rectangle { width: parent.width; height: 1; color: root.separator }
        Column {
            width: parent.width; spacing: 10; visible: !root.receiveTab
            Text {
                width: parent.width; wrapMode: Text.Wrap; color: root.secondary; font: root.font
                text: !root.controller.senderAvailable ? Language.I18n.text("ui.t_6de840a89b51")
                      : root.controller.sending ? Language.I18n.text("ui.t_d9cedf0db7d2")
                      : root.controller.pending ? Language.I18n.text("ui.t_4aaf969c174d")
                      : root.controller.connecting ? Language.I18n.text("ui.t_6e72f063b35d")
                      : Language.I18n.text("ui.t_9135a66c4cde")
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
                            Text { width: parent.width; text: ({streaming: "Mirroring", pin_required: modelData.credentialKind === "password" ? Language.I18n.text("ui.t_d89f8159ad5e") : Language.I18n.text("ui.t_e5c5fc026c2b"), connecting: "Connecting…"})[modelData.state] || modelData.state; color: root.secondary; font.pixelSize: 12 }
                            ControlCheckBox {
                                objectName: "mirroringAudio"; text: Language.I18n.text("ui.t_a47fa4d653a3"); visible: modelData.state === "streaming"
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
                    placeholderText: root.controller.pending && root.controller.pending.credentialKind === "password" ? Language.I18n.text("ui.t_8200ed70c797") : Language.I18n.text("ui.t_34fb12157318")
                    Accessible.name: placeholderText
                    onAccepted: if (text.length > 0) { root.controller.submitCredential(text); clear(); }
                    onVisibleChanged: { clear(); if (visible) Qt.callLater(() => credential.forceActiveFocus()); }
                }
                ControlButton { objectName: "mirroringSubmit"; width: parent.width; primary: true; text: Language.I18n.text("ui.t_1a2303ede074"); enabled: credential.text.length > 0; onClicked: { root.controller.submitCredential(credential.text); credential.clear(); } }
            }
            ControlButton {
                objectName: "mirroringDisconnect"; width: parent.width
                visible: root.controller.streams.length > 0 || root.controller.connecting
                text: root.controller.sending ? Language.I18n.text("ui.t_fb48910cfa4e") : Language.I18n.text("ui.t_bb8fd6f44c3a")
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
                    text: root.controller.scanning ? Language.I18n.text("ui.t_9f139dc2f04f") : Language.I18n.text("ui.t_202a7f24409a")
                }
                ControlButton { objectName: "mirroringRefresh"; width: parent.width; text: root.controller.scanning ? Language.I18n.text("ui.t_c31723ab3302") : Language.I18n.text("ui.t_fcd1aacad876"); enabled: root.controller.senderAvailable && !root.controller.scanning; onClicked: root.controller.refresh() }
            }
            Text { width: parent.width; visible: text !== ""; text: root.controller.senderError; wrapMode: Text.Wrap; color: root.warning; font.pixelSize: 12 }
        }
        Column {
            width: parent.width; spacing: 12; visible: root.receiveTab
            Text {
                width: parent.width; wrapMode: Text.Wrap; color: root.secondary; font: root.font
                text: !root.controller.receiverAvailable ? Language.I18n.text("ui.t_cdf4571e6d13")
                      : root.controller.receiverState === "streaming" ? Language.I18n.text("ui.t_d477abe25c0a") + (root.controller.receiverClient || Language.I18n.text("ui.t_5d9bbb593f62")) + Language.I18n.text("ui.t_fd1c62751508")
                      : root.controller.receiverState === "starting" ? Language.I18n.text("ui.t_e0d0d9e1b42b")
                      : root.controller.receiving ? Language.I18n.text("ui.t_f04bcc4da7b1") + root.controller.advertisedName + "”."
                      : Language.I18n.text("ui.t_71b7de415df3")
            }
            ControlTextField {
                objectName: "mirroringReceiverName"; width: parent.width; maximumLength: 40
                text: root.controller.receiverName; placeholderText: Language.I18n.text("ui.t_69deac3dc350")
                Accessible.name: Language.I18n.text("ui.t_06f5e496ff5d")
                enabled: !root.controller.receiving
                onTextEdited: root.controller.receiverName = text
            }
            Rectangle {
                width: parent.width; height: 78; radius: 12; visible: root.controller.receiverPin !== ""
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, .06)
                Column {
                    anchors.centerIn: parent; spacing: 4
                    Text { text: Language.I18n.text("ui.t_5ab67b4924c7"); color: root.secondary; font.pixelSize: 11; anchors.horizontalCenter: parent.horizontalCenter }
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
                text: root.controller.receiving ? Language.I18n.text("ui.t_f6e218482164") : Language.I18n.text("ui.t_8850ebcc36b1")
                onClicked: root.controller.setReceiver(!root.controller.receiving)
            }
            Text { width: parent.width; visible: text !== ""; text: root.controller.receiverError; wrapMode: Text.Wrap; color: root.warning; font.pixelSize: 12 }
            Text { width: parent.width; wrapMode: Text.Wrap; color: root.secondary; font.pixelSize: 11; text: Language.I18n.text("ui.t_e8a26c30952b") }
        }
        Text { width: parent.width; visible: text !== ""; text: Language.I18n.legacy(root.controller.error); wrapMode: Text.Wrap; color: root.warning; font.pixelSize: 12 }
    }
}

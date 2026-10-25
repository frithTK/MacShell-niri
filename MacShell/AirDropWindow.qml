import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtQuick.Dialogs

Window {
    id: root
    required property var controller
    property color foreground: "#f5f5f7"
    property color accent: "#0a84ff"
    property string family: "Inter"
    property bool receiveTab: false
    readonly property var state: controller.state
    readonly property bool dark: foreground.hslLightness > .5
    title: "macshell AirDrop"
    width: 440; height: 620
    minimumWidth: 440; maximumWidth: 440; minimumHeight: 620; maximumHeight: 620
    flags: Qt.Dialog | Qt.WindowTitleHint | Qt.WindowCloseButtonHint
    transientParent: null; visible: false
    color: dark ? "#24252b" : "#fafafb"
    function open() { controller.refresh(); show(); requestActivate(); }
    function dismiss() { if (state.pending) controller.answer(state.pending.key, false); hide(); }
    onClosing: event => { event.accepted = false; dismiss(); }
    Connections {
        target: root.controller
        function onShowRequested() { root.receiveTab = true; Qt.callLater(() => { root.show(); root.requestActivate(); }); }
    }
    Rectangle { anchors.fill: parent; color: root.color }
    ScrollView {
        anchors.fill: parent; anchors.margins: 16
        clip: true; contentWidth: availableWidth
        ControlMenu {
            id: controls
            width: parent.width; foreground: root.foreground; palette.highlight: root.accent; font.family: root.family
            focus: true; Keys.onEscapePressed: root.dismiss()
            contentItem: Column {
                spacing: 14
                Row {
                    spacing: 10
                    ShellGlyph { width: 30; height: 30; kind: "airdrop"; color: root.accent }
                    Column {
                        spacing: 3
                        Text { text: "AirDrop"; font.family: root.family; font.pixelSize: 20; font.weight: Font.DemiBold; color: root.foreground }
                        Text { text: root.controller.label; font.family: root.family; font.pixelSize: 12; color: controls.secondary }
                    }
                }
                Text {
                    width: parent.width; wrapMode: Text.Wrap; textFormat: Text.PlainText
                    color: controls.secondary; font.family: root.family; font.pixelSize: 12
                    text: root.controller.active ? "Visible for up to 10 minutes. Incoming transfers ask for your approval."
                        : root.controller.airplayBusy ? "Stop Screen Mirroring before enabling AirDrop."
                        : root.state.mode === "exclusive" || root.state.mode === "active-monitor" ? "AirDrop on this adapter disconnects Wi-Fi and interrupts internet calls. This mode is disabled in MacShell."
                        : "Share files with nearby Apple devices. Incoming transfers ask for your approval."
                }
                Text {
                    width: parent.width; visible: text !== "" && !root.controller.active && root.state.mode !== "exclusive" && root.state.mode !== "active-monitor"; text: root.state.notice || ""; textFormat: Text.PlainText
                    wrapMode: Text.Wrap; color: controls.secondary; font.family: root.family; font.pixelSize: 12
                }
                ControlTextField {
                    objectName: "airdropName"; width: parent.width; text: root.controller.receiverName
                    enabled: !root.controller.active; maximumLength: 40; placeholderText: "Name on Apple devices"
                    Accessible.name: "AirDrop name"; onTextEdited: root.controller.receiverName = text
                }
                ControlButton {
                    objectName: "airdropToggle"; width: parent.width
                    text: root.controller.active ? "Stop AirDrop" : root.state.mode && root.state.mode !== "shared" ? "Unavailable on this adapter" : "Enable for 10 minutes"
                    enabled: root.state.status !== "stopping" && (root.controller.active || (root.state.canStart === true && !root.controller.airplayBusy))
                    primary: !root.controller.active
                    onClicked: if (root.controller.active) root.controller.stop(); else root.controller.start()
                }
                Row {
                    width: parent.width; spacing: 6
                    ControlChoice { objectName: "airdropSendTab"; width: (parent.width - 6) / 2; text: "Send"; selected: !root.receiveTab; onClicked: root.receiveTab = false }
                    ControlChoice { objectName: "airdropReceiveTab"; width: (parent.width - 6) / 2; text: "Receive"; selected: root.receiveTab; onClicked: root.receiveTab = true }
                }
                Column {
                    width: parent.width; spacing: 10; visible: !root.receiveTab
                    ControlButton { objectName: "airdropChooseFiles"; text: "Choose files…"; enabled: !root.controller.transferring && (root.controller.active || root.state.canStart === true); onClicked: picker.open() }
                    Repeater {
                        model: root.state.files || []
                        Text { required property var modelData; width: parent.width; text: modelData.name; textFormat: Text.PlainText; elide: Text.ElideMiddle; color: root.foreground; font.family: root.family; font.pixelSize: 12 }
                    }
                    Text { width: parent.width; wrapMode: Text.Wrap; text: "On iPhone, choose AirDrop → Everyone for 10 Minutes, and keep it unlocked."; color: controls.secondary; font.family: root.family; font.pixelSize: 12 }
                    ControlButton { objectName: "airdropSearch"; text: root.state.scanning ? "Searching…" : "Find devices"; enabled: !root.state.scanning && root.state.status === "ready" && !root.controller.transferring; onClicked: root.controller.refresh() }
                    Repeater {
                        model: root.state.devices || []
                        ControlButton {
                            required property var modelData
                            objectName: "airdropDevice"; width: parent.width; text: "Send to " + modelData.name; primary: true
                            enabled: root.state.status === "ready" && (root.state.files || []).length > 0 && !root.controller.transferring && !root.state.pending
                            onClicked: root.controller.sendFiles(modelData.key)
                        }
                    }
                }
                Column {
                    width: parent.width; spacing: 10; visible: root.receiveTab
                    Text { width: parent.width; wrapMode: Text.Wrap; text: root.state.receiving ? "Choose this computer in the AirDrop sharing sheet on your Apple device." : "Enable AirDrop to receive files."; color: controls.secondary; font.family: root.family; font.pixelSize: 12 }
                    Text { width: parent.width; wrapMode: Text.Wrap; textFormat: Text.PlainText; text: "Save to: " + (root.state.folder || "Downloads/AirDrop"); color: controls.secondary; font.family: root.family; font.pixelSize: 12 }
                    Column {
                        width: parent.width; spacing: 8; visible: !!root.state.pending
                        Text { width: parent.width; wrapMode: Text.Wrap; textFormat: Text.PlainText; text: root.state.pending ? root.state.pending.name + " wants to share:" : ""; color: root.foreground; font.family: root.family; font.pixelSize: 14; font.weight: Font.DemiBold }
                        Repeater {
                            model: root.state.pending ? root.state.pending.files : []
                            Text { required property var modelData; width: parent.width; text: modelData.name; textFormat: Text.PlainText; elide: Text.ElideMiddle; color: root.foreground; font.family: root.family; font.pixelSize: 12 }
                        }
                        Repeater {
                            model: root.state.pending ? root.state.pending.urls : []
                            Text { required property string modelData; width: parent.width; text: modelData; textFormat: Text.PlainText; wrapMode: Text.Wrap; color: root.foreground; font.family: root.family; font.pixelSize: 12 }
                        }
                        Row {
                            spacing: 8
                            ControlButton { objectName: "airdropDecline"; text: "Decline"; onClicked: if (root.state.pending) root.controller.answer(root.state.pending.key, false) }
                            ControlButton { objectName: "airdropAccept"; text: "Accept"; primary: true; onClicked: if (root.state.pending) root.controller.answer(root.state.pending.key, true) }
                        }
                    }
                }
                ProgressBar { width: parent.width; visible: root.controller.transferring; indeterminate: !root.state.progress.total || root.state.transfer !== "sending"; from: 0; to: Math.max(1, root.state.progress.total); value: root.state.progress.sent }
                Text { width: parent.width; visible: ["idle", "waiting", "sending", "receiving"].indexOf(root.state.transfer) < 0; text: ({delivered: "Files delivered", received: "Files received", declined: "Transfer declined", failed: "Transfer failed", cancelled: "Transfer cancelled"})[root.state.transfer] || ""; color: root.foreground; font.family: root.family; font.pixelSize: 12 }
                Repeater { model: root.state.results || []; Text { required property string modelData; width: parent.width; text: modelData; textFormat: Text.PlainText; wrapMode: Text.Wrap; color: controls.secondary; font.family: root.family; font.pixelSize: 12 } }
                ControlButton { objectName: "airdropCancel"; visible: root.state.transfer === "waiting" || root.state.transfer === "sending"; text: "Cancel transfer"; onClicked: root.controller.cancel() }
                Text { width: parent.width; visible: text !== ""; text: root.controller.error; textFormat: Text.PlainText; wrapMode: Text.Wrap; color: controls.warning; font.family: root.family; font.pixelSize: 12 }
            }
        }
    }
    FileDialog {
        id: picker
        title: "Choose files for AirDrop"; fileMode: FileDialog.OpenFiles
        onAccepted: root.controller.setFiles(selectedFiles.map(url => String(url)))
    }
}

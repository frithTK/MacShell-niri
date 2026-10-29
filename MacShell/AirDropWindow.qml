import QtQuick
import "Locale" as Language
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
    title: Language.I18n.text("ui.t_1a4a572e8b8d")
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
                        Text { text: Language.I18n.text("ui.t_9ccc01839580"); font.family: root.family; font.pixelSize: 20; font.weight: Font.DemiBold; color: root.foreground }
                        Text { text: root.controller.label; font.family: root.family; font.pixelSize: 12; color: controls.secondary }
                    }
                }
                Text {
                    width: parent.width; wrapMode: Text.Wrap; textFormat: Text.PlainText
                    color: controls.secondary; font.family: root.family; font.pixelSize: 12
                    text: root.controller.active ? Language.I18n.text("ui.t_6cbe2a0b5cb7")
                        : root.controller.airplayBusy ? Language.I18n.text("ui.t_5d6a5337c12d")
                        : root.state.mode === "exclusive" || root.state.mode === "active-monitor" ? Language.I18n.text("ui.t_0382a3fcfe92")
                        : Language.I18n.text("ui.t_0979853ca4d2")
                }
                Text {
                    width: parent.width; visible: text !== "" && !root.controller.active && root.state.mode !== "exclusive" && root.state.mode !== "active-monitor"; text: root.state.notice || ""; textFormat: Text.PlainText
                    wrapMode: Text.Wrap; color: controls.secondary; font.family: root.family; font.pixelSize: 12
                }
                ControlTextField {
                    objectName: "airdropName"; width: parent.width; text: root.controller.receiverName
                    enabled: !root.controller.active; maximumLength: 40; placeholderText: Language.I18n.text("ui.t_7fdbce0f345a")
                    Accessible.name: Language.I18n.text("ui.t_668ff38a4527"); onTextEdited: root.controller.receiverName = text
                }
                ControlButton {
                    objectName: "airdropToggle"; width: parent.width
                    text: root.controller.active ? Language.I18n.text("ui.t_5b675a9b7c48") : root.state.mode && root.state.mode !== "shared" ? Language.I18n.text("ui.t_a6915470a170") : Language.I18n.text("ui.t_26f67d90f5db")
                    enabled: root.state.status !== "stopping" && (root.controller.active || (root.state.canStart === true && !root.controller.airplayBusy))
                    primary: !root.controller.active
                    onClicked: if (root.controller.active) root.controller.stop(); else root.controller.start()
                }
                Row {
                    width: parent.width; spacing: 6
                    ControlChoice { objectName: "airdropSendTab"; width: (parent.width - 6) / 2; text: Language.I18n.text("ui.t_f6f4688ff23d"); selected: !root.receiveTab; onClicked: root.receiveTab = false }
                    ControlChoice { objectName: "airdropReceiveTab"; width: (parent.width - 6) / 2; text: Language.I18n.text("ui.t_bac9d15ad9f1"); selected: root.receiveTab; onClicked: root.receiveTab = true }
                }
                Column {
                    width: parent.width; spacing: 10; visible: !root.receiveTab
                    ControlButton { objectName: "airdropChooseFiles"; text: Language.I18n.text("ui.t_6d4e30eea694"); enabled: !root.controller.transferring && (root.controller.active || root.state.canStart === true); onClicked: picker.open() }
                    Repeater {
                        model: root.state.files || []
                        Text { required property var modelData; width: parent.width; text: modelData.name; textFormat: Text.PlainText; elide: Text.ElideMiddle; color: root.foreground; font.family: root.family; font.pixelSize: 12 }
                    }
                    Text { width: parent.width; wrapMode: Text.Wrap; text: Language.I18n.text("ui.t_96f17afc9d92"); color: controls.secondary; font.family: root.family; font.pixelSize: 12 }
                    ControlButton { objectName: "airdropSearch"; text: root.state.scanning ? Language.I18n.text("ui.t_c31723ab3302") : Language.I18n.text("ui.t_be8b2f2c3185"); enabled: !root.state.scanning && root.state.status === "ready" && !root.controller.transferring; onClicked: root.controller.refresh() }
                    Repeater {
                        model: root.state.devices || []
                        ControlButton {
                            required property var modelData
                            objectName: "airdropDevice"; width: parent.width; text: Language.I18n.text("ui.t_2f859112f539") + modelData.name; primary: true
                            enabled: root.state.status === "ready" && (root.state.files || []).length > 0 && !root.controller.transferring && !root.state.pending
                            onClicked: root.controller.sendFiles(modelData.key)
                        }
                    }
                }
                Column {
                    width: parent.width; spacing: 10; visible: root.receiveTab
                    Text { width: parent.width; wrapMode: Text.Wrap; text: root.state.receiving ? Language.I18n.text("ui.t_a07f6f761073") : Language.I18n.text("ui.t_866ce2d87dc9"); color: controls.secondary; font.family: root.family; font.pixelSize: 12 }
                    Text { width: parent.width; wrapMode: Text.Wrap; textFormat: Text.PlainText; text: Language.I18n.text("ui.t_6e04f9b06f85") + (root.state.folder || Language.I18n.text("ui.t_bdadffa2ef36")); color: controls.secondary; font.family: root.family; font.pixelSize: 12 }
                    Column {
                        width: parent.width; spacing: 8; visible: !!root.state.pending
                        Text { width: parent.width; wrapMode: Text.Wrap; textFormat: Text.PlainText; text: root.state.pending ? root.state.pending.name + Language.I18n.text("ui.t_2dbdc0b2ed01") : ""; color: root.foreground; font.family: root.family; font.pixelSize: 14; font.weight: Font.DemiBold }
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
                            ControlButton { objectName: "airdropDecline"; text: Language.I18n.text("ui.t_a2d285b35287"); onClicked: if (root.state.pending) root.controller.answer(root.state.pending.key, false) }
                            ControlButton { objectName: "airdropAccept"; text: Language.I18n.text("ui.t_89713b9c9c1b"); primary: true; onClicked: if (root.state.pending) root.controller.answer(root.state.pending.key, true) }
                        }
                    }
                }
                ProgressBar { width: parent.width; visible: root.controller.transferring; indeterminate: !root.state.progress.total || root.state.transfer !== "sending"; from: 0; to: Math.max(1, root.state.progress.total); value: root.state.progress.sent }
                Text { width: parent.width; visible: ["idle", "waiting", "sending", "receiving"].indexOf(root.state.transfer) < 0; text: ({delivered: Language.I18n.text("ui.t_90402a40a24a"), received: Language.I18n.text("ui.t_d4caff88a956"), declined: Language.I18n.text("ui.t_8a85c344287c"), failed: Language.I18n.text("ui.t_efa06c28c406"), cancelled: Language.I18n.text("ui.t_b6321ee9a4a7")})[root.state.transfer] || ""; color: root.foreground; font.family: root.family; font.pixelSize: 12 }
                Repeater { model: root.state.results || []; Text { required property string modelData; width: parent.width; text: modelData; textFormat: Text.PlainText; wrapMode: Text.Wrap; color: controls.secondary; font.family: root.family; font.pixelSize: 12 } }
                ControlButton { objectName: "airdropCancel"; visible: root.state.transfer === "waiting" || root.state.transfer === "sending"; text: Language.I18n.text("ui.t_f48e8dc778dc"); onClicked: root.controller.cancel() }
                Text { width: parent.width; visible: text !== ""; text: Language.I18n.legacy(root.controller.error); textFormat: Text.PlainText; wrapMode: Text.Wrap; color: controls.warning; font.family: root.family; font.pixelSize: 12 }
            }
        }
    }
    FileDialog {
        id: picker
        title: Language.I18n.text("ui.t_ed92142b9a96"); fileMode: FileDialog.OpenFiles
        onAccepted: root.controller.setFiles(selectedFiles.map(url => String(url)))
    }
}

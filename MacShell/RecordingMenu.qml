import QtQuick
import "Locale" as Language
import QtQuick.Controls

ControlMenu {
    id: root
    required property var controller
    contentItem: Column {
        spacing: 14
        Item {
            width: parent.width; height: 36
            Button {
                objectName: "recordBack"
                width: 28; height: 30; anchors.verticalCenter: parent.verticalCenter
                background: Rectangle { radius: 8; color: parent.hovered ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, .08) : "transparent" }
                contentItem: WGlyph { kind: "chevL"; color: root.foreground; implicitWidth: 13; implicitHeight: 13 }
                Accessible.name: Language.I18n.text("ui.t_c9aecc5b06fe")
                onClicked: root.backRequested()
            }
            Text {
                x: 38; anchors.verticalCenter: parent.verticalCenter
                text: Language.I18n.text("ui.t_bc3c742893dc"); color: root.foreground
                font { family: root.font.family; pixelSize: 16; weight: Font.DemiBold }
            }
            Rectangle {
                visible: root.controller.recording
                anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                width: 9; height: 9; radius: 4.5; color: "#ff453a"
            }
        }
        Rectangle { width: parent.width; height: 1; color: root.separator }
        Text {
            width: parent.width; wrapMode: Text.Wrap; color: root.secondary
            font { family: root.font.family; pixelSize: 12 }
            text: root.controller.state === "countdown" ? Language.I18n.text("ui.t_54bc4e6fae77") + root.controller.countdown + "…"
                  : root.controller.recording ? Language.I18n.text("ui.t_10187d492bb4") + root.controller.timeLabel()
                  : ({choose: Language.I18n.text("ui.t_4f1e54fbc484"), selecting: Language.I18n.text("ui.t_b6da21544ddc"), mixing: Language.I18n.text("ui.t_ce8bdd01ba43"), starting: Language.I18n.text("ui.t_854e043d625f"), stopping: Language.I18n.text("ui.t_06692de28cea"), saving: Language.I18n.text("ui.t_9fd57213b23b"), result: Language.I18n.text("ui.t_b81274bafb79"), error: Language.I18n.text("ui.t_5bbd4bd225c8")})[root.controller.state] || root.controller.state
        }
        Column {
            width: parent.width; spacing: 14; visible: !root.controller.busy
            Rectangle {
                width: parent.width; height: sourceColumn.height + 24; radius: 14
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, .045)
                border.color: root.separator
                Column {
                    id: sourceColumn
                    x: 12; y: 12; width: parent.width - 24; spacing: 10
                    Text { text: Language.I18n.text("ui.t_095cabdd9e60"); color: root.secondary; font { family: root.font.family; pixelSize: 10; weight: Font.DemiBold; letterSpacing: .8 } }
                    ControlComboBox {
                        objectName: "recordMonitor"; width: parent.width
                        model: root.controller.outputs; textRole: "name"
                        displayText: currentIndex < 0 ? Language.I18n.text("ui.t_f62288e0363c") : currentText
                        currentIndex: root.controller.outputs.findIndex(o => o.name === root.controller.output)
                        onActivated: i => { root.controller.output = model[i].name; root.controller.geometry = ""; }
                    }
                    Rectangle {
                        width: parent.width; height: 34; radius: 9
                        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, .08)
                        Row {
                            anchors.fill: parent; anchors.margins: 3; spacing: 2
                            Repeater {
                                model: [Language.I18n.text("ui.t_7d5e2c080bd2"), Language.I18n.text("ui.t_bdaf2ff4edfe")]
                                delegate: Button {
                                    required property int index
                                    required property string modelData
                                    objectName: index === 0 ? "recordWhole" : "recordRegion"
                                    width: (parent.width - 2) / 2; height: parent.height
                                    readonly property bool selected: root.controller.region === (index === 1)
                                    background: Rectangle {
                                        radius: 6
                                        color: parent.selected ? (root.dark ? "#636366" : "#ffffff") : parent.hovered ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, .04) : "transparent"
                                        border.width: parent.selected ? 1 : 0
                                        border.color: root.dark ? Qt.rgba(1, 1, 1, .08) : Qt.rgba(0, 0, 0, .08)
                                    }
                                    contentItem: Text { text: parent.modelData; color: root.foreground; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; font { family: root.font.family; pixelSize: 11; weight: parent.selected ? Font.DemiBold : Font.Normal } }
                                    Accessible.name: modelData
                                    onClicked: root.controller.region = index === 1
                                }
                            }
                        }
                    }
                    ControlButton { visible: root.controller.region; width: parent.width; text: root.controller.geometry || Language.I18n.text("ui.t_f647df802d9d"); onClicked: root.controller.select() }
                }
            }
            Rectangle {
                width: parent.width; height: audioColumn.height + 24; radius: 14
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, .045)
                border.color: root.separator
                Column {
                    id: audioColumn
                    x: 12; y: 12; width: parent.width - 24; spacing: 10
                    Text { text: Language.I18n.text("ui.t_859e89a729c2"); color: root.secondary; font { family: root.font.family; pixelSize: 10; weight: Font.DemiBold; letterSpacing: .8 } }
                    ControlComboBox {
                        objectName: "recordAudio"; width: parent.width
                        model: [Language.I18n.text("ui.t_067606abf652"), Language.I18n.text("ui.t_c33bdd91ed88"), Language.I18n.text("ui.t_186352a881d0"), Language.I18n.text("ui.t_7d37b183dd9c")]
                        currentIndex: ["none", "system", "mic", "both"].indexOf(root.controller.audio)
                        onActivated: i => root.controller.audio = ["none", "system", "mic", "both"][i]
                    }
                    ControlComboBox {
                        objectName: "recordMicrophone"
                        visible: root.controller.audio === "mic" || root.controller.audio === "both"
                        width: parent.width; model: root.controller.microphones; textRole: "label"
                        displayText: currentIndex < 0 ? Language.I18n.text("ui.t_f9391bcbdfb3") : currentText
                        currentIndex: root.controller.microphones.findIndex(n => n.name === root.controller.microphone)
                        onActivated: i => root.controller.microphone = model[i].name
                    }
                    ControlComboBox {
                        objectName: "recordSystemAudio"
                        visible: root.controller.audio === "system" || root.controller.audio === "both"
                        width: parent.width; model: root.controller.sinks; textRole: "label"
                        displayText: currentIndex < 0 ? Language.I18n.text("ui.t_2c636f5bba48") : currentText
                        currentIndex: root.controller.sinks.findIndex(n => n.name === root.controller.sink)
                        onActivated: i => root.controller.sink = model[i].name
                    }
                    Text { visible: root.controller.audio === "both" && !root.controller.mixAvailable; width: parent.width; wrapMode: Text.Wrap; color: root.warning; text: Language.I18n.text("ui.t_d70900df2a3a"); font { family: root.font.family; pixelSize: 11 } }
                }
            }
            ControlButton {
                width: parent.width; implicitHeight: 36; objectName: "recordStart"; primary: true
                text: Language.I18n.text("ui.t_b0727bdd3c21")
                enabled: root.controller.available && root.controller.output !== "" && (!root.controller.region || root.controller.geometry !== "") && (root.controller.audio !== "both" || root.controller.mixAvailable)
                onClicked: root.controller.start()
            }
            Text { width: parent.width; text: Language.I18n.text("ui.t_ebbdd56b3207"); horizontalAlignment: Text.AlignHCenter; color: root.secondary; font { family: root.font.family; pixelSize: 11 } }
            Button {
                anchors.horizontalCenter: parent.horizontalCenter
                text: Language.I18n.text("ui.t_f127b1c8d655"); flat: true
                contentItem: Text { text: parent.text; color: root.secondary; font { family: root.font.family; pixelSize: 11 }
                    horizontalAlignment: Text.AlignHCenter }
                background: Rectangle { radius: 7; color: parent.hovered ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, .06) : "transparent" }
                onClicked: root.controller.prepare()
            }
        }
        ControlButton { visible: root.controller.busy; width: parent.width; text: root.controller.recording ? Language.I18n.text("ui.t_a7cd1395b365") : Language.I18n.text("common.cancel"); enabled: root.controller.state !== "stopping" && root.controller.state !== "saving"; onClicked: root.controller.stop() }
        Text { text: Language.I18n.legacy(root.controller.error); visible: text !== ""; color: root.warning; width: parent.width; wrapMode: Text.Wrap; font { family: root.font.family; pixelSize: 12 } }
        Text { text: root.controller.file; visible: text !== ""; color: root.secondary; width: parent.width; wrapMode: Text.WrapAnywhere; font { family: root.font.family; pixelSize: 11 } }
        Text { text: Language.I18n.text("ui.t_289b218507ec"); color: root.secondary; font { family: root.font.family; pixelSize: 10 }
            width: parent.width; wrapMode: Text.Wrap }
    }
}

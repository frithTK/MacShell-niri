import QtQuick
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
                Accessible.name: "Back to Control Center"
                onClicked: root.backRequested()
            }
            Text {
                x: 38; anchors.verticalCenter: parent.verticalCenter
                text: "Screen Recording"; color: root.foreground
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
            text: root.controller.state === "countdown" ? "Starting in " + root.controller.countdown + "…"
                  : root.controller.recording ? "Recording · " + root.controller.timeLabel()
                  : ({choose: "Choose a display or select an area to record.", selecting: "Select an area · Escape to cancel", mixing: "Preparing audio…", starting: "Waiting for the first frame…", stopping: "Finishing recording…", saving: "Checking the file…", result: "Recording saved", error: "Recording needs attention"})[root.controller.state] || root.controller.state
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
                    Text { text: "CAPTURE"; color: root.secondary; font { family: root.font.family; pixelSize: 10; weight: Font.DemiBold; letterSpacing: .8 } }
                    ControlComboBox {
                        objectName: "recordMonitor"; width: parent.width
                        model: root.controller.outputs; textRole: "name"
                        displayText: currentIndex < 0 ? "Choose a display…" : currentText
                        currentIndex: root.controller.outputs.findIndex(o => o.name === root.controller.output)
                        onActivated: i => { root.controller.output = model[i].name; root.controller.geometry = ""; }
                    }
                    Rectangle {
                        width: parent.width; height: 34; radius: 9
                        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, .08)
                        Row {
                            anchors.fill: parent; anchors.margins: 3; spacing: 2
                            Repeater {
                                model: ["Entire Display", "Selected Area"]
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
                    ControlButton { visible: root.controller.region; width: parent.width; text: root.controller.geometry || "Select area…"; onClicked: root.controller.select() }
                }
            }
            Rectangle {
                width: parent.width; height: audioColumn.height + 24; radius: 14
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, .045)
                border.color: root.separator
                Column {
                    id: audioColumn
                    x: 12; y: 12; width: parent.width - 24; spacing: 10
                    Text { text: "AUDIO"; color: root.secondary; font { family: root.font.family; pixelSize: 10; weight: Font.DemiBold; letterSpacing: .8 } }
                    ControlComboBox {
                        objectName: "recordAudio"; width: parent.width
                        model: ["No Audio", "System Audio", "Microphone", "System + Microphone"]
                        currentIndex: ["none", "system", "mic", "both"].indexOf(root.controller.audio)
                        onActivated: i => root.controller.audio = ["none", "system", "mic", "both"][i]
                    }
                    ControlComboBox {
                        objectName: "recordMicrophone"
                        visible: root.controller.audio === "mic" || root.controller.audio === "both"
                        width: parent.width; model: root.controller.microphones; textRole: "label"
                        displayText: currentIndex < 0 ? "Choose microphone…" : currentText
                        currentIndex: root.controller.microphones.findIndex(n => n.name === root.controller.microphone)
                        onActivated: i => root.controller.microphone = model[i].name
                    }
                    ControlComboBox {
                        objectName: "recordSystemAudio"
                        visible: root.controller.audio === "system" || root.controller.audio === "both"
                        width: parent.width; model: root.controller.sinks; textRole: "label"
                        displayText: currentIndex < 0 ? "Choose system audio output…" : currentText
                        currentIndex: root.controller.sinks.findIndex(n => n.name === root.controller.sink)
                        onActivated: i => root.controller.sink = model[i].name
                    }
                    Text { visible: root.controller.audio === "both" && !root.controller.mixAvailable; width: parent.width; wrapMode: Text.Wrap; color: root.warning; text: "Mixing requires pw-loopback."; font { family: root.font.family; pixelSize: 11 } }
                }
            }
            ControlButton {
                width: parent.width; implicitHeight: 36; objectName: "recordStart"; primary: true
                text: "Start Recording"
                enabled: root.controller.available && root.controller.output !== "" && (!root.controller.region || root.controller.geometry !== "") && (root.controller.audio !== "both" || root.controller.mixAvailable)
                onClicked: root.controller.start()
            }
            Text { width: parent.width; text: "Starts after a 3-second countdown"; horizontalAlignment: Text.AlignHCenter; color: root.secondary; font { family: root.font.family; pixelSize: 11 } }
            Button {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Refresh Devices"; flat: true
                contentItem: Text { text: parent.text; color: root.secondary; font { family: root.font.family; pixelSize: 11 }
                    horizontalAlignment: Text.AlignHCenter }
                background: Rectangle { radius: 7; color: parent.hovered ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, .06) : "transparent" }
                onClicked: root.controller.prepare()
            }
        }
        ControlButton { visible: root.controller.busy; width: parent.width; text: root.controller.recording ? "Stop Recording" : "Cancel"; enabled: root.controller.state !== "stopping" && root.controller.state !== "saving"; onClicked: root.controller.stop() }
        Text { text: root.controller.error; visible: text !== ""; color: root.warning; width: parent.width; wrapMode: Text.Wrap; font { family: root.font.family; pixelSize: 12 } }
        Text { text: root.controller.file; visible: text !== ""; color: root.secondary; width: parent.width; wrapMode: Text.WrapAnywhere; font { family: root.font.family; pixelSize: 11 } }
        Text { text: "Saved to Videos · Matroska (.mkv) · Up to 60 fps"; color: root.secondary; font { family: root.font.family; pixelSize: 10 }
            width: parent.width; wrapMode: Text.Wrap }
    }
}

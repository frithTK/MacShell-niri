import QtQuick
import "Locale" as Language

Column {
    id: menu
    required property var t
    required property var controller
    property real maxListHeight: 280
    signal backRequested()
    signal settingsRequested()
    spacing: 6

    Item {
        width: parent.width; height: 34
        Rectangle {
            width: 26; height: 28; radius: 8
            anchors.verticalCenter: parent.verticalCenter
            color: backMouse.containsMouse ? menu.t.hover : "transparent"
            WGlyph { anchors.centerIn: parent; width: 13; height: 13; kind: "chevL"; color: menu.t.fg }
            MouseArea { id: backMouse; anchors.fill: parent; hoverEnabled: true; onClicked: menu.backRequested() }
        }
        Text {
            x: 32; anchors.verticalCenter: parent.verticalCenter
            text: Language.I18n.text("ui.t_8bb29098b369")
            color: menu.t.fg; font.family: menu.t.fam; font.pixelSize: 15; font.weight: Font.DemiBold
        }
        Rectangle {
            objectName: "bluetoothPower"
            anchors.right: parent.right; anchors.rightMargin: 4
            anchors.verticalCenter: parent.verticalCenter
            width: 38; height: 22; radius: 11
            color: menu.controller.enabled ? menu.t.accent : menu.t.switchOff
            opacity: menu.controller.available && !menu.controller.busy ? 1 : 0.45
            Rectangle {
                x: menu.controller.enabled ? 18 : 2; y: 2
                width: 18; height: 18; radius: 9; color: "white"
                Behavior on x { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
            }
            MouseArea {
                anchors.fill: parent
                enabled: menu.controller.available && !menu.controller.busy
                onClicked: menu.controller.togglePower()
            }
        }
    }
    Rectangle { width: parent.width; height: 1; color: menu.t.sep }
    Text {
        visible: menu.controller.enabled && menu.controller.devices.length > 0
        x: 6; text: Language.I18n.text("ui.t_b3a77477986c")
        color: menu.t.fg2; font.family: menu.t.fam; font.pixelSize: 11; font.weight: Font.DemiBold
        topPadding: 3
    }
    Text {
        visible: !menu.controller.enabled || menu.controller.devices.length === 0
        width: parent.width
        topPadding: 16; bottomPadding: 16; leftPadding: 6; rightPadding: 6
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        text: menu.controller.loading ? Language.I18n.text("ui.t_b3f4c73bd205")
              : (!menu.controller.available ? Language.I18n.text("ui.t_282ff3956953")
              : (!menu.controller.enabled ? Language.I18n.text("ui.t_ec245d91ef26") : Language.I18n.text("ui.t_b2680ed17eca")))
        color: menu.t.fg2; font.family: menu.t.fam; font.pixelSize: 13
    }
    Flickable {
        id: list
        width: parent.width
        height: Math.min(menu.maxListHeight, devicesColumn.height)
        visible: menu.controller.enabled && devicesColumn.height > 0
        contentWidth: width; contentHeight: devicesColumn.height
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        clip: true
        Column {
            id: devicesColumn
            width: list.width
            spacing: 2
            Repeater {
                model: menu.controller.enabled ? menu.controller.devices : []
                delegate: Item {
                    id: row
                    required property var modelData
                    readonly property bool canPick: !menu.controller.busy && modelData.adapterEnabled && !modelData.blocked
                    objectName: "bluetoothDevice"
                    width: devicesColumn.width; height: 52
                    Rectangle {
                        anchors.fill: parent; radius: 12
                        color: rowMouse.containsMouse && row.canPick ? menu.t.hover : "transparent"
                    }
                    Rectangle {
                        x: 6; anchors.verticalCenter: parent.verticalCenter
                        width: 32; height: 32; radius: 16
                        color: row.modelData.connected ? menu.t.accent : menu.t.btnOff
                        WGlyph {
                            anchors.centerIn: parent; width: 16; height: 16
                            kind: menu.controller.deviceKind(row.modelData)
                            color: row.modelData.connected ? "white" : menu.t.fg
                        }
                    }
                    Column {
                        x: 48; anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 56 - (rowMouse.containsMouse && row.canPick ? actionLabel.implicitWidth + 8 : 0)
                        spacing: 2
                        Text {
                            width: parent.width; elide: Text.ElideRight
                            text: row.modelData.name
                            color: menu.t.fg; font.family: menu.t.fam; font.pixelSize: 13
                            font.weight: row.modelData.connected ? Font.DemiBold : Font.Normal
                        }
                        Text {
                            width: parent.width; elide: Text.ElideRight
                            text: menu.controller.deviceStatus(row.modelData)
                                  + (menu.controller.adapters.length > 1 ? " · " + row.modelData.adapterName : "")
                            color: menu.t.fg2; font.family: menu.t.fam; font.pixelSize: 11
                        }
                    }
                    Text {
                        id: actionLabel
                        anchors.right: parent.right; anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        visible: rowMouse.containsMouse && row.canPick
                        text: row.modelData.connected ? Language.I18n.text("ui.t_acfc5be785a9") : Language.I18n.text("ui.t_1a2303ede074")
                        color: menu.t.fg2; font.family: menu.t.fam; font.pixelSize: 11
                    }
                    MouseArea {
                        id: rowMouse
                        anchors.fill: parent; hoverEnabled: true
                        onClicked: if (row.canPick) menu.controller.pick(row.modelData)
                    }
                }
            }
        }
    }
    Rectangle {
        width: parent.width; height: 32; radius: 8; color: scanMouse.containsMouse ? menu.t.hover : "transparent"
        visible: menu.controller.enabled && menu.controller.pairingAvailable === true
        Text { x: 8; anchors.verticalCenter: parent.verticalCenter; text: menu.controller.discovering ? Language.I18n.text("ui.t_c48cf724a3f1") : Language.I18n.text("ui.t_dfbd0aad9fac"); color: menu.t.fg; font.pixelSize: 12 }
        MouseArea { id: scanMouse; anchors.fill: parent; enabled: !menu.controller.busy; hoverEnabled: true; onClicked: menu.controller.discover() }
    }
    Text { visible: menu.controller.discovering === true; text: Language.I18n.text("ui.t_2d7bd0c2b84a"); color: menu.t.fg2; font.pixelSize: 11 }
    Flickable {
        width: parent.width; height: Math.min(150, otherList.height); contentHeight: otherList.height; clip: true
        Column {
            id: otherList; width: parent.width
            Repeater {
                model: menu.controller.others || []
                delegate: Rectangle {
                    required property var modelData
                    width: otherList.width; height: 42; radius: 8; color: otherMouse.containsMouse ? menu.t.hover : "transparent"
                    Text { x: 8; width: parent.width - 55; anchors.verticalCenter: parent.verticalCenter; elide: Text.ElideRight; text: modelData.name; color: menu.t.fg; font.pixelSize: 12 }
                    Text { anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter; text: Language.I18n.text("ui.t_989da04b0aaa"); color: menu.t.accent; font.pixelSize: 11 }
                    MouseArea { id: otherMouse; anchors.fill: parent; hoverEnabled: true; enabled: !menu.controller.busy; onClicked: menu.controller.pair(modelData) }
                }
            }
        }
    }
    Rectangle {
        width: parent.width; height: 28; color: "transparent"; visible: menu.controller.busy
        Text { anchors.centerIn: parent; text: Language.I18n.text("ui.t_56196683592d"); color: menu.t.fg2; font.pixelSize: 12 }
        MouseArea { anchors.fill: parent; onClicked: menu.controller.cancel() }
    }
    Text {
        visible: menu.controller.error !== "" || menu.controller.statusError !== ""
        width: parent.width; leftPadding: 6; rightPadding: 6
        wrapMode: Text.WordWrap
        text: menu.controller.error || menu.controller.statusError
        color: "#FF6961"; font.family: menu.t.fam; font.pixelSize: 12
    }
    Rectangle { width: parent.width; height: 1; color: menu.t.sep }
    Row {
        width: parent.width; spacing: 4
        Rectangle {
            width: parent.width - refreshButton.width - 4; height: 32; radius: 8
            color: settingsMouse.containsMouse ? menu.t.hover : "transparent"
            Text {
                x: 8; anchors.verticalCenter: parent.verticalCenter
                text: Language.I18n.text("ui.t_449de564aaf3")
                color: menu.t.fg; font.family: menu.t.fam; font.pixelSize: 12
            }
            MouseArea { id: settingsMouse; anchors.fill: parent; hoverEnabled: true; onClicked: menu.settingsRequested() }
        }
        Rectangle {
            id: refreshButton
            width: 66; height: 32; radius: 8
            color: refreshMouse.containsMouse ? menu.t.hover : "transparent"
            Text {
                anchors.centerIn: parent
                text: menu.controller.refreshing ? Language.I18n.text("ui.t_dfe40efe921f") : Language.I18n.text("ui.t_0e9161011702")
                color: menu.t.fg2; font.family: menu.t.fam; font.pixelSize: 11
            }
            MouseArea {
                id: refreshMouse
                anchors.fill: parent; hoverEnabled: true
                onClicked: { menu.controller.error = ""; menu.controller.refresh(); }
            }
        }
    }
}

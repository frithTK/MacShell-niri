import QtQuick
import "Locale" as Language
import QtQuick.Controls

Item {
    id: root
    property string title: ""
    property color foreground: "white"
    property string family: "Inter Variable"
    property bool backVisible: true
    signal backRequested()
    implicitHeight: 36
    Button {
        objectName: "menuBack"
        visible: root.backVisible
        width: 28; height: 30; anchors.verticalCenter: parent.verticalCenter
        Accessible.name: Language.I18n.text("ui.t_c9aecc5b06fe")
        background: Rectangle {
            radius: 8; color: parent.hovered || parent.activeFocus ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, .10) : "transparent"
        }
        contentItem: WGlyph { kind: "chevL"; color: root.foreground; implicitWidth: 13; implicitHeight: 13 }
        onClicked: root.backRequested()
    }
    Text {
        x: root.backVisible ? 38 : 4; width: parent.width - x - 4
        anchors.verticalCenter: parent.verticalCenter
        text: root.title; color: root.foreground; elide: Text.ElideRight
        font { family: root.family; pixelSize: 16; weight: Font.DemiBold }
    }
}

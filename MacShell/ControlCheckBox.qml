import QtQuick
import QtQuick.Controls

CheckBox {
    id: root
    implicitHeight: 28
    indicator: Rectangle {
        x: 0; y: (root.height - height) / 2; width: 16; height: 16; radius: 4
        color: root.checked ? root.palette.highlight : root.palette.base
        border.width: root.activeFocus ? 2 : 1
        border.color: root.activeFocus ? root.palette.highlight : Qt.rgba(.5, .5, .5, .35)
        WGlyph { anchors.centerIn: parent; width: 10; height: 10; kind: "check"; color: "white"; visible: root.checked }
    }
    contentItem: Text { text: root.text; font: root.font; color: root.palette.text; leftPadding: 24; verticalAlignment: Text.AlignVCenter }
}

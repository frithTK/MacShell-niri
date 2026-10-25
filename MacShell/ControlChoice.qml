import QtQuick
import QtQuick.Controls

ItemDelegate {
    id: root
    property bool selected: false
    implicitHeight: 36
    leftPadding: 12; rightPadding: 32
    Accessible.role: Accessible.RadioButton
    Accessible.checked: selected
    background: Rectangle {
        radius: 9
        color: root.hovered || root.activeFocus ? Qt.rgba(.5, .5, .5, .15)
                                               : root.selected ? Qt.rgba(.5, .5, .5, .09) : "transparent"
    }
    contentItem: Text { text: root.text; font: root.font; color: root.palette.text; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight; opacity: root.enabled ? 1 : .45 }
    WGlyph { anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter; width: 13; height: 13; kind: "check"; visible: root.selected; color: root.palette.highlight }
}

import QtQuick
import QtQuick.Controls

TextField {
    id: root
    implicitHeight: 36
    padding: 10; color: palette.text; selectionColor: palette.highlight
    background: Rectangle {
        radius: 8; color: root.palette.base
        border.width: root.activeFocus ? 2 : 1
        border.color: root.activeFocus ? root.palette.highlight : Qt.rgba(.5, .5, .5, .25)
    }
}

import QtQuick
import QtQuick.Controls

Button {
    id: root
    property bool primary: false
    implicitWidth: Math.max(80, contentItem.implicitWidth + 24)
    implicitHeight: 32
    padding: 8
    contentItem: Text {
        text: root.text
        textFormat: Text.PlainText
        color: root.primary ? "white" : root.palette.buttonText
        opacity: root.enabled ? 1 : .45
        font.family: root.font.family
        font.pixelSize: 12
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }
    background: Rectangle {
        radius: 8
        color: root.primary ? (root.down ? Qt.darker(root.palette.highlight, 1.15) : root.palette.highlight) : root.down ? Qt.lighter(root.palette.button, 1.15) : root.palette.button
        opacity: root.enabled ? 1 : .45
        border.width: 1
        border.color: root.activeFocus ? root.palette.highlight : Qt.rgba(.5, .5, .5, .12)
    }
}

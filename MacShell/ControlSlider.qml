import QtQuick
import QtQuick.Controls

Slider {
    id: root
    implicitHeight: 30
    leftPadding: 9; rightPadding: 9
    background: Rectangle {
        x: root.leftPadding; y: (root.height - height) / 2
        width: root.availableWidth; height: 5; radius: 2.5
        color: Qt.rgba(.5, .5, .5, .32)
        Rectangle { width: root.visualPosition * parent.width; height: parent.height; radius: parent.radius; color: root.palette.highlight }
    }
    handle: Rectangle {
        x: root.leftPadding + root.visualPosition * root.availableWidth - width / 2
        y: (root.height - height) / 2; width: 18; height: 18; radius: 9
        color: root.pressed ? "#e5e5e7" : "white"
        border.width: root.activeFocus ? 2 : 1
        border.color: root.activeFocus ? root.palette.highlight : Qt.rgba(0, 0, 0, .18)
        opacity: root.enabled ? 1 : .45
    }
}

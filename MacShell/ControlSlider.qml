import QtQuick
import QtQuick.Controls

Slider {
    id: root
    implicitHeight: 30
    leftPadding: 9; rightPadding: 9
    background: Rectangle {
        id: sliderTrack
        x: root.leftPadding; y: (root.height - height) / 2
        width: root.availableWidth; height: 8; radius: 4
        color: Qt.rgba(.5, .5, .5, .32)
        Rectangle { width: root.visualPosition * parent.width; height: parent.height; radius: parent.radius; color: root.palette.highlight }
    }
    handle: Rectangle {
        x: root.leftPadding + root.visualPosition * root.availableWidth - width / 2
        y: (root.height - height) / 2; width: 20; height: 20; radius: 10
        color: root.pressed ? "#e5e5e7" : "white"
        border.width: root.activeFocus ? 2 : 1
        border.color: root.activeFocus ? root.palette.highlight : Qt.rgba(0, 0, 0, .18)
        opacity: root.enabled ? 1 : .45
        scale: root.pressed ? 1.12 : 1
        Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        ControlGlassLens { anchors.fill: parent; active: root.pressed; track: sliderTrack; trackOrigin: Qt.point(root.handle.x - sliderTrack.x, root.handle.y - sliderTrack.y) }
        gradient: Gradient {
            GradientStop { position: 0; color: "#ffffff" }
            GradientStop { position: 1; color: root.pressed ? "#cbd2db" : "#e6e8eb" }
        }
    }
}

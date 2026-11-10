import QtQuick
import QtQuick.Controls

Switch {
    id: root
    implicitHeight: 32
    implicitWidth: Math.max(46, label.implicitWidth + (root.text ? 58 : 0))
    spacing: 12
    indicator: Rectangle {
        id: track
        width: Math.min(46, root.width); height: 22; radius: 11
        x: root.width - width; anchors.verticalCenter: parent.verticalCenter
        color: root.checked ? root.palette.highlight : Qt.rgba(.5, .5, .5, .38)
        opacity: root.enabled ? 1 : .4
        border.width: root.activeFocus ? 2 : 0; border.color: root.palette.text
        Behavior on color { ColorAnimation { duration: 160 } }
        Item { id: trackPicture; anchors.fill: parent; visible: false
            Rectangle { anchors.fill: parent; radius: height / 2; color: root.checked ? root.palette.highlight : Qt.rgba(.5, .5, .5, .38) }
        }
        Rectangle {
            id: knob
            x: 2 + root.visualPosition * (parent.width - width - 4)
            y: 2; width: Math.min(27, parent.width - 4); height: 18; radius: 9
            color: root.down ? "#f2f2f2" : "#ffffff"
            border.width: 1; border.color: Qt.rgba(0, 0, 0, .08)
            gradient: Gradient {
                GradientStop { position: 0; color: root.down ? "#f8f9fa" : "#ffffff" }
                GradientStop { position: 1; color: root.down ? "#cbd2db" : "#e6e8eb" }
            }
            Behavior on x { NumberAnimation { duration: root.down ? 0 : 220; easing.type: Easing.OutBack; easing.overshoot: 1.1 } }
            scale: root.down ? 1.06 : 1
            Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
            ControlGlassLens { anchors.fill: parent; active: root.down; track: trackPicture; trackOrigin: Qt.point(knob.x, knob.y) }
        }
    }
    contentItem: Text {
        id: label; text: root.text; font: root.font; color: root.palette.text
        rightPadding: root.text ? 58 : 0; verticalAlignment: Text.AlignVCenter; wrapMode: Text.Wrap
        opacity: root.enabled ? 1 : .45
    }
}

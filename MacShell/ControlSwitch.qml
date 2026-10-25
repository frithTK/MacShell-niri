import QtQuick
import QtQuick.Controls

Switch {
    id: root
    implicitHeight: 32
    implicitWidth: label.implicitWidth + 50
    spacing: 12
    indicator: Rectangle {
        width: 38; height: 22; radius: 11
        x: root.width - width; anchors.verticalCenter: parent.verticalCenter
        color: root.checked ? root.palette.highlight : Qt.rgba(.5, .5, .5, .4)
        opacity: root.enabled ? 1 : .4
        border.width: root.activeFocus ? 2 : 0; border.color: root.palette.text
        Rectangle {
            x: root.checked ? 18 : 2; y: 2; width: 18; height: 18; radius: 9
            color: "white"
            Behavior on x { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }
        }
    }
    contentItem: Text {
        id: label; text: root.text; font: root.font; color: root.palette.text
        rightPadding: 50; verticalAlignment: Text.AlignVCenter; wrapMode: Text.Wrap
        opacity: root.enabled ? 1 : .45
    }
}

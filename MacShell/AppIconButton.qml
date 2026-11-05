import QtQuick
import QtQuick.Controls

Button {
    id: root
    property bool dark: true
    property string glyph: ""
    property string label: ""
    property color iconColor: dark ? "#91c2ff" : "#176ec3"
    implicitWidth: 36; implicitHeight: 34; padding: 0
    Accessible.name: label
    ToolTip.text: label
    ToolTip.delay: 600
    ToolTip.visible: hovered && enabled && label !== ""
    background: Rectangle {
        radius: 9
        color: root.down ? (root.dark ? "#505056" : "#d4d4da")
            : root.hovered ? (root.dark ? "#3d3d42" : "#e5e5ea") : "transparent"
        border.width: root.activeFocus ? 1 : 0
        border.color: root.dark ? "#83bfff" : "#2273c9"
    }
    contentItem: Item {
        opacity: root.enabled ? 1 : .4
        ShellGlyph {
            anchors.centerIn: parent; width: 18; height: 18
            kind: root.glyph
            color: root.iconColor
        }
    }
}

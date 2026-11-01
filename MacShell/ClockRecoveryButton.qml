import QtQuick
import QtQuick.Controls

Button {
    id: root
    property bool darkMode: true
    property bool primary: false
    implicitWidth: Math.max(92, label.implicitWidth + 24)
    implicitHeight: 32
    contentItem: Text {
        id: label
        text: root.text; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
        color: root.primary ? "white" : (root.darkMode ? "#f5f5f7" : "#1d1d1f")
        opacity: root.enabled ? 1 : 0.5
        font.pixelSize: 13; font.weight: Font.Medium
    }
    background: Rectangle {
        radius: 7
        color: root.primary ? (root.down ? "#0064d7" : "#0a84ff")
                            : (root.down ? (root.darkMode ? "#53535b" : "#d3d3d7")
                                         : (root.darkMode ? "#45454d" : "#dedee2"))
        border.width: root.visualFocus ? 2 : 0
        border.color: root.darkMode ? "white" : "#005fcc"
        opacity: root.enabled ? 1 : 0.55
    }
}

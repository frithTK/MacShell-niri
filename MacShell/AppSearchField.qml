import QtQuick
import QtQuick.Controls

TextField {
    id: root
    property bool dark: true
    implicitHeight: 34
    leftPadding: 32; rightPadding: 10
    selectByMouse: true
    color: dark ? "#f5f5f7" : "#1d1d1f"
    placeholderTextColor: dark ? "#aaaab3" : "#686870"
    font.pixelSize: 13
    background: Rectangle {
        radius: 9
        color: root.dark ? "#3a3a3e" : "#dedee2"
        border.width: 1
        border.color: root.activeFocus ? (root.dark ? "#8abfff" : "#4d91db") : (root.dark ? "#48484c" : "#d2d2d7")
        Item {
            x: 11; anchors.verticalCenter: parent.verticalCenter; width: 14; height: 14
            Rectangle { x: 1; y: 1; width: 9; height: 9; radius: 5; color: "transparent"; border.width: 1.5; border.color: root.placeholderTextColor }
            Rectangle { x: 9; y: 9; width: 5; height: 1.5; rotation: 45; transformOrigin: Item.Left; radius: 1; color: root.placeholderTextColor }
        }
    }
}

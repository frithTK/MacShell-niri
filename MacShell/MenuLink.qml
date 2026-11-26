import QtQuick

// Settings row on the glass itself, same treatment as Bluetooth settings.
Rectangle {
    id: root
    property string text: ""
    property bool enabled: true
    property color foreground: "white"
    property color hoverColor: Qt.rgba(foreground.r, foreground.g, foreground.b, .08)
    property string family: ""
    signal clicked()
    implicitWidth: labelItem.implicitWidth + 16
    implicitHeight: 32
    height: 32
    radius: 8
    opacity: enabled ? 1 : .45
    color: area.containsMouse && enabled ? hoverColor : "transparent"
    Text {
        id: labelItem
        x: 8
        width: Math.max(0, parent.width - 16)
        anchors.verticalCenter: parent.verticalCenter
        elide: Text.ElideRight
        text: root.text
        color: root.foreground
        font.family: root.family
        font.pixelSize: 12
    }
    MouseArea {
        id: area
        anchors.fill: parent
        enabled: root.enabled
        hoverEnabled: true
        onClicked: root.clicked()
    }
}

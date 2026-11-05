import QtQuick
import "Locale" as Language

Rectangle {
    id: badge
    property string layoutName: ""
    property string labelObjectName: ""
    property string fontFamily: "Inter"
    property real unit: 1
    property real maximumWidth: 1000
    width: Math.min(Math.max(0, maximumWidth), Math.max(100 * unit, label.implicitWidth + 24 * unit))
    height: 26 * unit; radius: height / 2
    color: Qt.rgba(0, 0, 0, 0.55)
    border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.22)
    Text {
        id: label
        objectName: badge.labelObjectName
        anchors.fill: parent; anchors.leftMargin: 12 * badge.unit; anchors.rightMargin: 12 * badge.unit
        text: Language.I18n.text("lock.keyboard_layout") + ": " + (badge.layoutName ? Language.I18n.legacy(badge.layoutName) : Language.I18n.text("lock.keyboard_unknown"))
        textFormat: Text.PlainText; elide: Text.ElideRight
        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
        color: "white"; font.family: badge.fontFamily; font.pixelSize: Math.max(12, 12 * badge.unit); font.weight: Font.Medium
        Accessible.role: Accessible.StaticText
        Accessible.name: text
    }
}

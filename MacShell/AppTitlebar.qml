import QtQuick
import QtQuick.Controls
import QtQuick.Window

Item {
    id: root
    property var window: null
    property bool dark: true
    property string family: "Inter Variable"
    property color barColor: dark ? "#303033" : "#e9e9ec"
    property color titleColor: dark ? "#f5f5f7" : "#1d1d1f"
    property string title: ""
    property string titleObjectName: ""
    property string closeLabel: "Close"
    property string minimizeLabel: "Minimize"
    property string maximizeLabel: "Maximize"
    property string controlObjectPrefix: ""
    signal closeRequested()
    implicitHeight: 52

    Rectangle {
        anchors.fill: parent
        radius: 12
        color: root.barColor
        Rectangle {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: parent.height / 2
            color: parent.color
        }
        Rectangle {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: 1
            color: root.dark ? "#454548" : "#d0d0d4"
        }
    }
    DragHandler { target: null; onActiveChanged: if (active && root.window) root.window.startSystemMove() }
    Text {
        objectName: root.titleObjectName
        anchors.centerIn: parent
        width: Math.max(0, parent.width - 190)
        text: root.title; textFormat: Text.PlainText; elide: Text.ElideRight
        horizontalAlignment: Text.AlignHCenter
        color: root.titleColor
        opacity: root.window && !root.window.active ? .65 : 1
        font.family: root.family; font.pixelSize: 13; font.weight: Font.DemiBold
    }
    Row {
        id: lights
        x: 13; anchors.verticalCenter: parent.verticalCenter
        spacing: 2
        HoverHandler { id: lightsHover }
        Repeater {
            model: [
                {color: "#ff5f57", glyph: "×"},
                {color: "#febc2e", glyph: "−"},
                {color: "#28c840", glyph: "↗"}
            ]
            delegate: Button {
                id: light
                required property var modelData
                required property int index
                width: 20; height: 24; padding: 0
                objectName: root.controlObjectPrefix ? root.controlObjectPrefix + index : ""
                Accessible.name: index === 0 ? root.closeLabel : index === 1 ? root.minimizeLabel : root.maximizeLabel
                background: Item {}
                contentItem: Item {
                    Rectangle {
                        anchors.centerIn: parent; width: 13; height: 13; radius: 6.5
                        color: root.window && !root.window.active && !lightsHover.hovered ? (root.dark ? "#626266" : "#b9b9bd") : light.modelData.color
                        border.width: 1; border.color: Qt.rgba(0, 0, 0, .12)
                        Text {
                            anchors.centerIn: parent; anchors.verticalCenterOffset: -0.5
                            visible: lightsHover.hovered || light.activeFocus
                            text: light.modelData.glyph; color: "#57000000"
                            font.pixelSize: 10; font.bold: true
                        }
                    }
                }
                onClicked: {
                    if (!root.window) return;
                    if (index === 0) root.closeRequested();
                    else if (index === 1) root.window.showMinimized();
                    else if (root.window.visibility === Window.Maximized) root.window.showNormal();
                    else root.window.showMaximized();
                }
            }
        }
    }
}

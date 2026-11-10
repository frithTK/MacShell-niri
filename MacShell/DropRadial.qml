import QtQuick
import "DropTools.js" as DropTools

Item {
    id: root
    property var actions: []
    property int current: 0
    property string family: "Inter Variable"
    property color foreground: "#f5f5f7"
    property color accent: "#0a84ff"
    property color fill: "#3a3a3e"
    property color muted: "#686870"
    signal chosen(string id)
    signal cancelled()
    readonly property var currentAction: (actions && actions.length && actions[current]) ? actions[current] : null
    implicitWidth: 280
    implicitHeight: 280
    focus: true

    function cycle(delta) {
        if (!root.actions || root.actions.length === 0)
            return;
        root.current = DropTools.nextIndex(root.actions, root.current, delta);
    }

    function activate() {
        var row = root.currentAction;
        if (row && row.available !== false)
            root.chosen(row.id);
    }

    function reset() {
        root.current = DropTools.firstAvailable(root.actions);
    }

    onActionsChanged: root.reset()

    Repeater {
        model: root.actions
        delegate: Item {
            required property var modelData
            required property int index
            readonly property real angle: (index / Math.max(root.actions.length, 1)) * Math.PI * 2 - Math.PI / 2
            width: 72
            height: 72
            x: root.width / 2 + Math.cos(angle) * 96 - width / 2
            y: root.height / 2 + Math.sin(angle) * 96 - height / 2
            Rectangle {
                anchors.fill: parent
                radius: width / 2
                color: index === root.current ? root.accent : root.fill
                opacity: modelData.available === false ? 0.4 : 1
                border.width: index === root.current ? 0 : 1
                border.color: Qt.rgba(1, 1, 1, 0.12)
            }
            Text {
                anchors.centerIn: parent
                width: parent.width - 8
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: modelData.label || modelData.id
                color: index === root.current ? "#ffffff" : root.foreground
                font.family: root.family
                font.pixelSize: 11
                font.weight: Font.DemiBold
            }
            MouseArea {
                anchors.fill: parent
                enabled: modelData.available !== false
                onClicked: {
                    root.current = index;
                    root.chosen(modelData.id);
                }
            }
        }
    }

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Escape) {
            root.cancelled();
            event.accepted = true;
        } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Tab || event.key === Qt.Key_Down) {
            root.cycle(1);
            event.accepted = true;
        } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Backtab || event.key === Qt.Key_Up) {
            root.cycle(-1);
            event.accepted = true;
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
            root.activate();
            event.accepted = true;
        }
    }
}

import QtQuick

Item {
    id: g
    required property var t
    property var model: []
    property int current: 0
    property real segWidth: 72
    property int dragIndex: -1
    readonly property int shownIndex: dragIndex >= 0 ? dragIndex : current
    property real markerLeft: 2 + Math.max(0, shownIndex) * segWidth
    property real markerRight: 2 + (Math.max(0, shownIndex) + 1) * segWidth
    Behavior on markerLeft { NumberAnimation { duration: 300; easing.type: Easing.OutBack; easing.overshoot: 1.1 } }
    Behavior on markerRight { NumberAnimation { duration: 220; easing.type: Easing.OutBack; easing.overshoot: 1.1 } }
    signal picked(int index)
    activeFocusOnTab: true
    Accessible.role: Accessible.Grouping
    Keys.onLeftPressed: event => {
        if (g.enabled && g.model.length > 0) g.picked(Math.max(0, g.current - 1));
        event.accepted = true;
    }
    Keys.onRightPressed: event => {
        if (g.enabled && g.model.length > 0) g.picked(Math.min(g.model.length - 1, g.current + 1));
        event.accepted = true;
    }
    width: model.length * segWidth + 4
    height: 26
    Rectangle { anchors.fill: parent; radius: height / 2; color: g.t.ctrl; border.width: g.activeFocus ? 1 : 0; border.color: g.t.text }
    Rectangle {
        id: marker
        visible: g.shownIndex >= 0 && g.shownIndex < g.model.length
        y: 2; x: g.markerLeft
        width: Math.max(1, g.markerRight - g.markerLeft); height: parent.height - 4; radius: height / 2
        color: g.t.ctrlSel
        border.width: g.t.dark ? 0 : 1; border.color: Qt.rgba(0, 0, 0, 0.10)
        scale: pointer.pressed ? 1.04 : 1
        Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    }
    Row {
        x: 2; y: 2
        Repeater {
            model: g.model
            delegate: Item {
                required property var modelData
                required property int index
                width: g.segWidth; height: g.height - 4
                Text {
                    anchors.centerIn: parent; width: parent.width - 6
                    text: parent.modelData; color: g.t.text; font.family: g.t.fam
                    font.pixelSize: 12; font.weight: parent.index === g.current ? Font.Medium : Font.Normal
                    horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
                }
            }
        }
    }
    Item {
        id: lensPicture
        width: g.width; height: g.height; visible: false
        Rectangle { anchors.fill: parent; radius: height / 2; color: g.t.ctrl }
        Row {
            x: 2; y: 2
            Repeater {
                model: g.model
                delegate: Item {
                    required property var modelData
                    width: g.segWidth; height: g.height - 4
                    Text { anchors.centerIn: parent; width: parent.width - 6; text: parent.modelData; color: g.t.text; font.family: g.t.fam; font.pixelSize: 12; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight }
                }
            }
        }
    }
    ControlGlassLens {
        objectName: "segmentGlassLens"
        x: marker.x; y: marker.y; width: marker.width; height: marker.height
        active: pointer.pressed && marker.visible
        track: lensPicture; trackOrigin: Qt.point(x, y)
    }
    MouseArea {
        id: pointer
        anchors.fill: parent
        enabled: g.enabled && g.model.length > 0
        function indexAt(x) { return Math.max(0, Math.min(g.model.length - 1, Math.floor((x - 2) / g.segWidth))); }
        onPressed: mouse => { g.forceActiveFocus(); g.dragIndex = indexAt(mouse.x); }
        onPositionChanged: mouse => { if (pressed) g.dragIndex = indexAt(mouse.x); }
        onReleased: mouse => { let selected = indexAt(mouse.x); g.dragIndex = -1; g.picked(selected); }
        onCanceled: g.dragIndex = -1
    }
}

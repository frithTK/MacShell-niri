import QtQuick

Item {
    id: root
    property Item targetItem: null
    property Item coordinateItem: null
    property real offsetX: 0
    property real offsetY: 0
    property point origin: Qt.point(0, 0)
    property point pressedAt: Qt.point(0, 0)
    property bool dragging: false
    readonly property bool pressed: mouse.pressed && mouse.pressedButtons === Qt.LeftButton
    signal moveRequested(real x, real y)
    signal selectRequested()
    signal contextRequested()
    function reset() { offsetX = 0; offsetY = 0; }
    onEnabledChanged: if (!enabled) { reset(); dragging = false; }
    MouseArea {
        id: mouse; anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
        onPressed: event => {
            root.dragging = false;
            if (!root.targetItem || !root.coordinateItem) return;
            root.origin = Qt.point(root.targetItem.x, root.targetItem.y);
            root.pressedAt = mapToItem(root.coordinateItem, event.x, event.y);
        }
        onPositionChanged: event => {
            if (!pressed || pressedButtons !== Qt.LeftButton || !root.targetItem || !root.coordinateItem) return;
            var point = mapToItem(root.coordinateItem, event.x, event.y);
            var dx = point.x - root.pressedAt.x, dy = point.y - root.pressedAt.y;
            if (!root.dragging && dx * dx + dy * dy < 64) return;
            root.dragging = true;
            root.offsetX = Math.max(0, Math.min(root.coordinateItem.width - root.targetItem.width, root.origin.x + dx)) - root.origin.x;
            root.offsetY = Math.max(0, Math.min(root.coordinateItem.height - root.targetItem.height, root.origin.y + dy)) - root.origin.y;
        }
        onReleased: event => {
            if (root.dragging && event.button === Qt.LeftButton) root.moveRequested(root.origin.x + root.offsetX, root.origin.y + root.offsetY);
            root.reset();
        }
        onClicked: event => { if (root.dragging) return; if (event.button === Qt.RightButton) root.contextRequested(); else root.selectRequested(); }
        onCanceled: { root.reset(); root.dragging = false; }
    }
}

import QtQuick
import QtQml.Models

// mapToItem() is not a reactive binding to ancestor transforms. Observe the
// actual ancestors/transform objects instead of polling or summing local x/y.
Item {
    id: mapping
    property Item sourceItem: null
    property Item targetItem: null
    property real padding: 0
    property rect localRect: sourceItem ? Qt.rect(-padding, -padding, sourceItem.width + 2 * padding, sourceItem.height + 2 * padding) : Qt.rect(0, 0, 0, 0)
    property var watched: []
    property int revision: 0
    readonly property rect rect: {
        revision;
        return sourceItem && targetItem ? sourceItem.mapToItem(targetItem, localRect) : Qt.rect(0, 0, 0, 0);
    }
    readonly property real scaleX: localRect.width > 0 ? rect.width / localRect.width : 1
    readonly property real scaleY: localRect.height > 0 ? rect.height / localRect.height : 1
    // Snapshot after visibility bindings settle. Reading effective visibility
    // from a blur-region binding during window construction can re-enter it.
    property real effectiveOpacity: 0
    function updateOpacity() {
        var value = 1;
        for (var item = sourceItem; item; item = item.parent) {
            if (!item.visible) { value = 0; break; }
            value *= item.opacity;
        }
        effectiveOpacity = sourceItem ? value : 0;
    }
    function invalidate() { revision++; }
    function rebuild() {
        var objects = [];
        function add(item) {
            while (item) {
                if (objects.indexOf(item) < 0) objects.push(item);
                for (var i = 0; i < item.transform.length; i++) {
                    var transform = item.transform[i];
                    if (objects.indexOf(transform) < 0) objects.push(transform);
                }
                item = item.parent;
            }
        }
        add(sourceItem); add(targetItem);
        watched = objects;
        invalidate();
        Qt.callLater(updateOpacity);
    }
    onSourceItemChanged: Qt.callLater(rebuild)
    onTargetItemChanged: Qt.callLater(rebuild)
    Component.onCompleted: rebuild()
    Instantiator {
        model: mapping.watched
        delegate: Connections {
            required property var modelData
            target: modelData
            ignoreUnknownSignals: true
            function onXChanged() { mapping.invalidate(); }
            function onYChanged() { mapping.invalidate(); }
            function onWidthChanged() { mapping.invalidate(); }
            function onHeightChanged() { mapping.invalidate(); }
            function onScaleChanged() { mapping.invalidate(); }
            function onRotationChanged() { mapping.invalidate(); }
            function onTransformOriginChanged() { mapping.invalidate(); }
            function onVisibleChanged() { Qt.callLater(mapping.updateOpacity); }
            function onOpacityChanged() { Qt.callLater(mapping.updateOpacity); }
            function onParentChanged() { Qt.callLater(mapping.rebuild); }
            function onTransformChanged() { Qt.callLater(mapping.rebuild); }
            function onAngleChanged() { mapping.invalidate(); }
            function onXScaleChanged() { mapping.invalidate(); }
            function onYScaleChanged() { mapping.invalidate(); }
            function onOriginChanged() { mapping.invalidate(); }
            function onMatrixChanged() { mapping.invalidate(); }
        }
    }
}

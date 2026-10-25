import QtQuick
import QtQuick.Window
import Quickshell

Region {
    id: root
    property var registry: null
    item: registry && registry.enabled && registry.editing && !registry.blocked ? registry.surfaceItem : null
    regions: registry ? registry.activeTargets.map(target => target.nativeRegion).filter(region => !!region) : []
    function commit() {
        var surface = registry ? registry.surfaceItem : null;
        var window = surface ? surface.Window.window : null;
        if (window && window.visible) window.update();
    }
    // Submit an empty input region too, including after the last target unmounts.
    onChanged: Qt.callLater(commit)
}

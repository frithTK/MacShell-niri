import QtQuick
import Quickshell

// BackgroundEffect changes are double-buffered Wayland surface state. Clearing
// a region after the last animation frame must still submit a surface commit.
Region {
    id: region
    property var host: null
    property var renderWindow: host && host.contentItem ? host.contentItem.Window.window : null
    readonly property var activeSurfaces: host ? host.glassSurfaces.filter(s => s && s.blurActive) : []
    property int clearFrames: 0
    // Niri can retain pixels when the last framebuffer effect disappears.
    // First repaint it with a region outside the surface, then remove it after
    // two submitted frames. Do not leave an invisible blur effect running.
    x: -1; y: -1
    width: clearFrames > 0 ? 1 : 0
    height: clearFrames > 0 ? 1 : 0
    regions: activeSurfaces.map(s => s.blurRegion)
    onActiveSurfacesChanged: clearFrames = activeSurfaces.length === 0 ? 2 : 0
    property Connections frameWatcher: Connections {
        target: region.renderWindow
        ignoreUnknownSignals: true
        function onFrameSwapped() {
            if (region.clearFrames <= 0) return;
            region.clearFrames--;
            Qt.callLater(region.commit);
        }
    }

    function commit() {
        if (host && host.visible && renderWindow) renderWindow.update();
    }
    // Coalesce changes until visibility, geometry and BackgroundEffect bindings
    // settle. This also covers an empty union and destroyed glass surfaces.
    onChanged: Qt.callLater(commit)
    onRenderWindowChanged: Qt.callLater(commit)
}

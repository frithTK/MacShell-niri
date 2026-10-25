import QtQuick
import "GlassTheme.js" as GlassTheme
import Quickshell

// The compositor supplies the actual pixels below this surface. Never paint a
// wallpaper reconstruction when the compositor hasn't supplied window positions.
Rectangle {
    id: glass
    property bool dark: true
    property real frosting: .42
    property real intensity: 1
    property real blurAmount: 5
    property bool blurEnabled: true
    property var host: QsWindow.window
    property var registeredHost: null
    readonly property bool blurActive: blurEnabled && blurAmount > 0 && geometry.effectiveOpacity > .01 && geometry.rect.width > 0 && geometry.rect.height > 0
    MappedRect { id: geometry; sourceItem: glass; targetItem: glass.host ? glass.host.contentItem : null }
    // Region.item only observes that item's own geometry. An opening panel can
    // move/scale all of its descendants without changing their local geometry.
    readonly property Region blurRegion: Region {
        x: Math.floor(geometry.rect.x); y: Math.floor(geometry.rect.y)
        width: Math.max(0, Math.ceil(geometry.rect.x + geometry.rect.width) - x)
        height: Math.max(0, Math.ceil(geometry.rect.y + geometry.rect.height) - y)
        radius: Math.round(glass.radius * Math.min(geometry.scaleX, geometry.scaleY))
    }
    // Light material needs enough white over dark windows for dark text/icons.
    color: dark ? Qt.rgba(.09, .095, .11, .15 + frosting * .65)
                : Qt.rgba(1, 1, 1, GlassTheme.lightTint(frosting))
    border.width: 1
    border.color: dark ? Qt.rgba(1, 1, 1, .12 + Math.min(intensity, 2.5) * .055)
                       : Qt.rgba(1, 1, 1, .32 + Math.min(intensity, 2.5) * .09)
    function register() {
        if (registeredHost && registeredHost.glassSurfaces !== undefined)
            registeredHost.glassSurfaces = registeredHost.glassSurfaces.filter(s => s !== glass);
        registeredHost = host;
        if (host && host.glassSurfaces !== undefined)
            host.glassSurfaces = host.glassSurfaces.concat([glass]);
    }
    onHostChanged: register()
    Component.onCompleted: register()
    Component.onDestruction: {
        if (registeredHost && registeredHost.glassSurfaces !== undefined)
            registeredHost.glassSurfaces = registeredHost.glassSurfaces.filter(s => s !== glass);
    }
    // Retain a distinct glass material when the compositor supplies the blur:
    // intensity changes the highlights, without inventing window refraction.
    Rectangle {
        id: highlights
        anchors.fill: parent; anchors.margins: 1
        radius: Math.max(0, glass.radius - 1)
        readonly property real sheen: Math.max(0, Math.min(2.5, glass.intensity))
        gradient: Gradient {
            GradientStop { position: 0; color: Qt.rgba(1, 1, 1, .09 * highlights.sheen) }
            GradientStop { position: .35; color: "transparent" }
            GradientStop { position: .72; color: "transparent" }
            GradientStop { position: 1; color: Qt.rgba(1, 1, 1, .035 * highlights.sheen) }
        }
    }
    Rectangle {
        anchors.fill: parent; anchors.margins: 1
        radius: Math.max(0, glass.radius - 1)
        color: "transparent"; border.width: 1
        border.color: glass.dark ? Qt.rgba(0, 0, 0, .16) : Qt.rgba(0, 0, 0, .07)
    }
}

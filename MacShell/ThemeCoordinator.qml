import QtQuick

// Appearance lives on the Dock. Push look into the Menu Bar so Control Center
// and popovers follow the same glass preset as the Dock and widgets.
Item {
    id: root
    visible: false
    property var bar: null
    property var dock: null
    property bool initialized: false
    property bool synchronizing: false
    readonly property bool ready: !!bar && !!dock && bar.settingsReady && dock.settingsReady
    onReadyChanged: { if (ready) initialize(); else initialized = false; }
    Component.onCompleted: initialize()
    function initialize() {
        if (!ready || initialized) return;
        initialized = true;
        syncLook();
    }
    function copyKey(k) {
        if (root.bar[k] === undefined || root.dock[k] === undefined) return;
        if (root.bar[k] !== root.dock[k]) root.bar[k] = root.dock[k];
    }
    function syncLook() {
        if (!initialized || !ready || synchronizing) return;
        synchronizing = true;
        var keys = ["darkMode", "glassOpacity", "glassBlur", "glassLiquid", "glassRim", "glassGrain", "accent", "fontFamily"];
        for (var i = 0; i < keys.length; i++)
            copyKey(keys[i]);
        if (root.dock.dockStyle !== undefined && root.bar.barStyle !== undefined) {
            var style = root.dock.dockStyle === "liquid" ? "liquid" : "blur";
            if (root.bar.barStyle !== style) root.bar.barStyle = style;
        }
        synchronizing = false;
    }
    Connections {
        target: root.bar
        ignoreUnknownSignals: true
        function onDarkModeChanged() {
            if (!root.ready || root.synchronizing) return;
            if (root.dock.darkMode !== root.bar.darkMode) root.dock.darkMode = root.bar.darkMode;
        }
    }
    Connections {
        target: root.dock
        ignoreUnknownSignals: true
        function onDarkModeChanged() { root.syncLook(); }
        function onGlassOpacityChanged() { root.syncLook(); }
        function onGlassBlurChanged() { root.syncLook(); }
        function onGlassLiquidChanged() { root.syncLook(); }
        function onGlassRimChanged() { root.syncLook(); }
        function onGlassGrainChanged() { root.syncLook(); }
        function onDockStyleChanged() { root.syncLook(); }
        function onAccentChanged() { root.syncLook(); }
        function onFontFamilyChanged() { root.syncLook(); }
    }
}

import QtQuick

// Keep the two legacy settings files in agreement. Settings/Dock owns the
// initial appearance; changes from either live component update the other.
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
        sync(dock);
    }
    function sync(source) {
        if (!initialized || !ready || synchronizing) return;
        synchronizing = true;
        var dark = source.darkMode;
        if (bar.darkMode !== dark) bar.darkMode = dark;
        if (dock.darkMode !== dark) dock.darkMode = dark;
        synchronizing = false;
    }
    Connections {
        target: root.bar
        function onDarkModeChanged() { root.sync(root.bar); }
    }
    Connections {
        target: root.dock
        function onDarkModeChanged() { root.sync(root.dock); }
    }
}

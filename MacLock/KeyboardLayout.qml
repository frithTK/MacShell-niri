import QtQuick
import Quickshell
import Quickshell.Io

// Read the compositor's active layout directly; never infer it from typed keys.
Scope {
    id: root
    property bool active: true
    property string socketPath: Quickshell.env("NIRI_SOCKET")
    property var names: []
    property int currentIndex: -1
    readonly property string name: currentIndex >= 0 && currentIndex < names.length ? names[currentIndex] : ""

    function clear() { names = []; currentIndex = -1; }
    function start() {
        retry.stop();
        if (!active || !socketPath) { stream.connected = false; clear(); return; }
        if (!stream.connected) stream.connected = true;
    }
    function accept(line) {
        var event;
        try { event = JSON.parse(line); } catch (error) { return; }
        if (!event || typeof event !== "object") return;
        if (event.Err) {
            clear();
            stream.connected = false;
            if (active && socketPath) retry.restart();
        } else if (event.KeyboardLayoutsChanged) {
            var layouts = event.KeyboardLayoutsChanged.keyboard_layouts;
            if (!layouts || !Array.isArray(layouts.names) || !layouts.names.every(n => typeof n === "string" && n.trim() !== "")) { clear(); return; }
            names = layouts.names.map(n => n.trim());
            currentIndex = Number.isInteger(layouts.current_idx) && layouts.current_idx >= 0 && layouts.current_idx < names.length ? layouts.current_idx : -1;
        } else if (event.KeyboardLayoutSwitched) {
            var index = event.KeyboardLayoutSwitched.idx;
            currentIndex = Number.isInteger(index) && index >= 0 && index < names.length ? index : -1;
        }
    }
    onActiveChanged: start()
    onSocketPathChanged: { stream.connected = false; clear(); start(); }
    Component.onCompleted: start()
    Timer { id: retry; interval: 2000; onTriggered: root.start() }
    Socket {
        id: stream
        path: root.socketPath
        parser: SplitParser { onRead: line => root.accept(line) }
        onConnectionStateChanged: {
            root.clear();
            if (connected) { retry.stop(); write('"EventStream"\n'); flush(); }
            else if (root.active && root.socketPath) retry.restart();
        }
        onError: {
            root.clear();
            if (root.active && root.socketPath) retry.restart();
        }
    }
}

import QtQuick
import Quickshell

QtObject {
    id: window
    property var data: ({})
    readonly property double id: data.id || 0
    readonly property string address: String(id)
    readonly property string appId: data.app_id || ""
    readonly property int pid: Number(data.pid || 0)
    property string currentTitle: ""
    readonly property string title: currentTitle
    onDataChanged: currentTitle = data.title || ""
    function updateTitle(value) {
        var next = value || "";
        if (next === currentTitle) return;
        data.title = next;
        currentTitle = next;
    }
    readonly property bool activated: data.is_focused || false
    readonly property bool fullscreen: data.fullscreen > 0
    readonly property bool minimized: false
    readonly property var workspace: data.workspace || null
    readonly property var lastIpcObject: Object.assign({}, data, {title: currentTitle})
    readonly property var wayland: window
    readonly property var screens: Quickshell.screens.filter(function(s) { return s.name === window.data.output; })
    function activate() { Niri.action(["focus-window", "--id", String(id)]); }
    function close() { Niri.action(["close-window", "--id", String(id)]); }
}

import QtQuick
import Quickshell

Scope {
    id: root
    property bool exported: false
    property string source: "none"
    property var menus: []
    property int pid: 0
    property string windowId: ""
    property string appId: ""
    property var token: 0
    property int focusId: 0
    property int activateId: 0
    property var pending: ({ pid: 0, windowId: "", appId: "" })
    readonly property bool ready: svc.ready
    signal changed()

    function setFocus(tl) {
        root.pending = {
            pid: tl ? Number(tl.pid || (tl.data && tl.data.pid) || 0) : 0,
            windowId: tl ? String(tl.id || "") : "",
            appId: tl ? String(tl.appId || "") : ""
        };
        debounce.restart();
    }

    function focusWindow(pid, windowId, appId) {
        if (!svc.ready)
            return -1;
        root.focusId = svc.send("focus", {
            pid: Number(pid) || 0,
            windowId: String(windowId || ""),
            appId: String(appId || "")
        });
        return root.focusId;
    }

    function activate(id) {
        if (!svc.ready || !root.exported)
            return -1;
        root.activateId = svc.send("activate", {
            id: String(id || ""),
            token: root.token,
            windowId: root.windowId,
            pid: root.pid
        });
        return root.activateId;
    }

    function apply(message) {
        root.exported = message.exported === true;
        root.source = String(message.source || "none");
        root.menus = Array.isArray(message.menus) ? message.menus : [];
        root.pid = Number(message.pid || 0);
        root.windowId = String(message.windowId || "");
        root.appId = String(message.appId || "");
        root.token = message.token !== undefined ? message.token : 0;
        root.changed();
    }

    Timer {
        id: debounce
        interval: 80
        onTriggered: root.focusWindow(root.pending.pid, root.pending.windowId, root.pending.appId)
    }

    JsonService {
        id: svc
        launcher: "app-menu.sh"
        enabled: true
        serializeRequests: true
        onConnected: root.focusWindow(root.pending.pid, root.pending.windowId, root.pending.appId)
        onReceived: message => {
            if (!message || message.type !== "result")
                return;
            if (message.id === root.focusId) {
                root.apply(message);
                return;
            }
            if (message.id === root.activateId && message.success === false && message.error === "stale")
                debounce.restart();
        }
    }
}

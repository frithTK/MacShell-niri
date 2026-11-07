import QtQuick
import Quickshell

Scope {
    id: root
    property bool enabled: false
    property string storePath: ""
    property var events: []
    property var deleted: []
    property var pending: null
    property bool refreshPending: false
    property string error: ""
    readonly property bool ready: service.ready
    readonly property bool busy: pending !== null
    signal saved()
    signal settled()
    function uuid() {
        return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, function(c) {
            var r = Math.floor(Math.random() * 16); return (c === "x" ? r : (r & 3 | 8)).toString(16);
        });
    }
    function send(action, data) {
        if (!ready || pending) return false;
        pending = {action: action, data: data || {}, request: -1};
        pending.request = service.send(action, pending.data);
        if (pending.request < 0) { pending = null; return false; }
        error = ""; return true;
    }
    function load() { return send("load", {}); }
    function save(event, title, allDay, day, start, end) {
        var data = {id: event ? event.id : uuid(), title: title, allDay: allDay, date: day, start: start, end: end};
        if (event) data.revision = event.revision;
        return send(event ? "update" : "create", data);
    }
    function setDeleted(event, deleted) {
        if (!event) return false;
        return send("delete", {id: event.id, revision: event.revision, deleted: deleted});
    }
    JsonService {
        id: service; script: "calendar_service.py"; arguments: ["--store", root.storePath]
        enabled: root.enabled && root.storePath !== ""
        onConnected: { if (root.pending) root.pending.request = service.send(root.pending.action, root.pending.data); else root.load(); }
        onReadyChanged: if (!ready && root.pending) root.pending.request = -1
        onReceived: message => {
            if (message.type === "unavailable") { root.error = message.error || "Calendar storage unavailable."; return; }
            if (message.type === "changed") { if (root.pending) root.refreshPending = true; else root.load(); return; }
            if (message.type !== "result" || !root.pending || message.id !== root.pending.request) return;
            var operation = root.pending; root.pending = null;
            if (!message.success) { root.error = message.error || "Calendar operation failed."; root.settled(); return; }
            root.error = "";
            if (operation.action === "load") {
                root.events = message.result.events || []; root.deleted = message.result.deleted || [];
                if (root.refreshPending) { root.refreshPending = false; root.load(); return; }
                root.settled(); return;
            }
            if (operation.action === "create" || operation.action === "update") root.saved();
            if (!root.load()) root.settled();
        }
    }
}

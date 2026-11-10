import QtQuick
import Quickshell

Scope {
    id: root
    property var items: []
    property int count: 0
    property bool full: false
    property bool loading: false
    property bool mutating: false
    property int listId: 0
    property int mutateId: 0
    property string lastError: ""
    readonly property bool ready: svc.ready
    signal changed()
    signal restored(bool ok, string error, string suggested, var item)
    signal emptied(bool ok, int removed, var failed)

    function refresh() {
        if (!svc.ready)
            return -1;
        root.loading = true;
        root.listId = svc.send("list", {});
        return root.listId;
    }

    function restore(id, asName) {
        if (root.mutating)
            return -2;
        if (!svc.ready)
            return -1;
        root.mutating = true;
        root.lastError = "";
        root.mutateId = svc.send("restore", { id: String(id || ""), as: String(asName || "") });
        if (root.mutateId < 0)
            root.mutating = false;
        return root.mutateId;
    }

    function empty() {
        if (root.mutating)
            return -2;
        if (!svc.ready)
            return -1;
        root.mutating = true;
        root.lastError = "";
        root.mutateId = svc.send("empty", {});
        if (root.mutateId < 0)
            root.mutating = false;
        return root.mutateId;
    }

    JsonService {
        id: svc
        launcher: "trash.sh"
        enabled: true
        onConnected: root.refresh()
        onReceived: message => {
            if (!message || message.type !== "result")
                return;
            if (message.id === root.listId) {
                root.items = Array.isArray(message.items) ? message.items : [];
                root.count = Number(message.count || root.items.length);
                root.full = message.full === true || root.count > 0;
                root.loading = false;
                root.changed();
                return;
            }
            if (message.id !== root.mutateId)
                return;
            root.mutating = false;
            root.mutateId = 0;
            var ok = message.success === true;
            if (message.removed !== undefined) {
                root.lastError = ok ? "" : String(message.error || "");
                root.emptied(ok, Number(message.removed || 0), Array.isArray(message.failed) ? message.failed : []);
                root.refresh();
                return;
            }
            var error = ok ? "" : String(message.error || "denied");
            root.lastError = error;
            root.restored(ok, error, String(message.suggested || ""), message.item || null);
            if (ok || error !== "conflict")
                root.refresh();
        }
    }
}

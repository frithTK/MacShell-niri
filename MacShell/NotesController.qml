import QtQuick
import Quickshell

Scope {
    id: root
    property bool enabled: false
    property string storePath: ""
    property string initialId: ""
    property bool autoRefresh: false
    property bool selectFirst: true
    property var sharedService: null
    readonly property var service: sharedService || localService
    property var notes: []
    property var deletedNotes: []
    property string selectedId: ""
    property string body: ""
    property int revision: 0
    property bool dirty: false
    property var pending: null
    property var deletedNote: null
    property string error: ""
    readonly property bool ready: enabled && service.ready
    readonly property bool busy: pending !== null
    signal clean()

    function uuid() {
        return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, function(c) {
            var r = Math.floor(Math.random() * 16);
            return (c === "x" ? r : (r & 3 | 8)).toString(16);
        });
    }
    function send(action, data) {
        if (!ready || pending) return false;
        pending = {action: action, data: data || {}, request: -1};
        pending.request = service.send(action, pending.data);
        if (pending.request < 0) { pending = null; return false; }
        error = "";
        return true;
    }
    function reload() { if (!dirty && !pending) return send("list", {}); return false; }
    function select(id) {
        if (dirty || pending) return false;
        var note = notes.find(n => n.id === id);
        if (!note) return false;
        selectedId = note.id; revision = note.revision; body = note.body; error = "";
        return true;
    }
    function create() { if (dirty || pending) return false; return send("create", {id: uuid()}); }
    function edit(value) {
        if (!selectedId || value === body) return;
        body = value; dirty = true; error = ""; autosave.restart();
    }
    function flush() {
        autosave.stop();
        if (dirty && !pending && ready) send("save", {id: selectedId, body: body, revision: revision});
        else if (!dirty && !pending) clean();
    }
    function remove() {
        if (!selectedId || dirty || pending) return false;
        return send("delete", {id: selectedId, revision: revision});
    }
    function saveCopy() {
        if (!dirty || pending) return false;
        autosave.stop();
        return send("save-copy", {id: uuid(), body: body});
    }
    function undoDelete() {
        if (!deletedNote || dirty || pending) return false;
        return restore(deletedNote);
    }
    function restore(note) {
        if (!note || dirty || pending) return false;
        return send("restore", {id: note.id, revision: note.revision});
    }
    function upsert(note) {
        var copy = notes.filter(n => n.id !== note.id);
        copy.unshift(note); notes = copy;
    }
    function connected() {
        if (!enabled || !service.ready) return;
        if (pending) pending.request = service.send(pending.action, pending.data);
        else if (!dirty) reload();
        else flush();
    }
    onEnabledChanged: if (enabled && sharedService && sharedService.ready) Qt.callLater(() => { if (!root.pending) root.connected(); })
    Timer { id: autosave; interval: 250; onTriggered: root.flush() }
    Timer { interval: 2000; repeat: true; running: root.autoRefresh && root.enabled && root.ready; onTriggered: root.reload() }
    JsonService {
        id: localService
        script: "notes_service.py"
        arguments: ["--store", root.storePath]
        enabled: !root.sharedService && root.enabled && root.storePath !== ""
    }
    Connections {
        target: root.service
        enabled: root.enabled
        function onConnected() { root.connected(); }
        function onReadyChanged() { if (!root.service.ready && root.pending) root.pending.request = -1; }
        function onReceived(message) {
            if (message.type === "unavailable") { root.error = message.error || "Notes storage unavailable."; return; }
            if (message.type !== "result" || !root.pending || message.id !== root.pending.request) return;
            var operation = root.pending; root.pending = null;
            if (!message.success) { root.error = message.error || "Notes operation failed."; if (!root.dirty) root.clean(); return; }
            var value = message.result;
            root.error = "";
            if (operation.action === "list") {
                root.notes = value || [];
                if (!root.dirty) {
                    if (!root.selectedId && root.initialId !== "") {
                        if (!root.select(root.initialId)) root.error = "Note no longer exists.";
                    } else if (!root.selectedId && root.selectFirst && root.notes.length) root.select(root.notes[0].id);
                    else if (root.selectedId && !root.notes.some(n => n.id === root.selectedId)) { root.selectedId = ""; root.body = ""; }
                    else if (root.selectedId) root.select(root.selectedId);
                }
                root.send("list-deleted", {});
            } else if (operation.action === "list-deleted") {
                root.deletedNotes = value || [];
                if (root.initialId && !root.selectedId) root.error = "Note no longer exists.";
            } else if (operation.action === "create" || operation.action === "restore") {
                root.upsert(value); root.selectedId = value.id; root.revision = value.revision; root.body = value.body;
                if (operation.action === "restore") {
                    root.deletedNotes = root.deletedNotes.filter(n => n.id !== value.id);
                    if (root.deletedNote && root.deletedNote.id === value.id) root.deletedNote = null;
                }
            } else if (operation.action === "save") {
                root.revision = value.revision; root.upsert(value);
                root.dirty = root.body !== operation.data.body;
            } else if (operation.action === "save-copy") {
                root.upsert(value); root.selectedId = value.id; root.revision = value.revision;
                root.dirty = root.body !== operation.data.body;
            } else if (operation.action === "delete") {
                root.deletedNote = value; root.notes = root.notes.filter(n => n.id !== value.id);
                root.deletedNotes = [value].concat(root.deletedNotes.filter(n => n.id !== value.id));
                root.selectedId = ""; root.body = ""; root.revision = 0;
                if (root.notes.length) root.select(root.notes[0].id);
            }
            if (root.dirty) root.flush(); else if (!root.pending) root.clean();
        }
    }
}

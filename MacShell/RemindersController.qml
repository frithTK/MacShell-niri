import QtQuick
import Quickshell

Scope {
    id: root
    property bool enabled: false
    property string storePath: ""
    property var lists: []
    property var tasks: []
    property var deletedLists: []
    property var deletedTasks: []
    property string selectedList: "inbox"
    property var pending: null
    property var lastDeleted: null
    property var lastDeletedList: null
    property string error: ""
    property string schedulerState: "starting"
    property bool refreshPending: false
    readonly property bool ready: service.ready
    readonly property bool busy: pending !== null
    signal taskCreated(string value)
    signal listCreated(string value)
    signal taskUpdated(string id, string field)
    signal listUpdated(string id, string field)
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
    function selectList(id) {
        if (pending || !lists.some(l => l.id === id)) return false;
        selectedList = id; return true;
    }
    function createList(name) {
        if (!String(name || "").trim()) return false;
        return send("create-list", {id: uuid(), name: name});
    }
    function createTask(name) {
        if (!String(name || "").trim()) return false;
        return send("create-task", {id: uuid(), listId: selectedList, title: name});
    }
    function update(task, field, value) {
        if (!task || !task.id) return false;
        return send("update", {id: task.id, revision: task.revision, field: field, value: value});
    }
    function setDetails(task, value, dueAt, repeat) {
        if (!task || !task.id) return false;
        return send("set-details", {id: task.id, revision: task.revision, title: value, dueAt: dueAt, repeat: repeat});
    }
    function resolveAlert(task, retry) {
        if (!task || !task.id) return false;
        return send("resolve-alert", {id: task.id, revision: task.revision, dueAt: task.due_at, retry: retry, commandId: uuid()});
    }
    function undoDelete() { return lastDeleted && update(lastDeleted, "deleted", false); }
    function updateList(list, field, value) {
        if (!list || !list.id || list.id === "inbox") return false;
        return send("update-list", {id: list.id, revision: list.revision, field: field, value: value});
    }
    function undoList() { return lastDeletedList && updateList(lastDeletedList, "deleted", false); }
    JsonService {
        id: service
        script: "reminders_service.py"
        arguments: ["--store", root.storePath]
        enabled: root.enabled && root.storePath !== ""
        onConnected: {
            if (root.pending) root.pending.request = service.send(root.pending.action, root.pending.data);
            else root.load();
        }
        onReadyChanged: if (!ready) { root.schedulerState = "unavailable"; if (root.pending) root.pending.request = -1; }
        onReceived: message => {
            if (message.type === "unavailable") { root.error = message.error || "Task storage unavailable."; return; }
            if (message.type === "scheduler") { root.schedulerState = message.state; return; }
            if (message.type === "changed") {
                if (root.pending) root.refreshPending = true;
                else root.load();
                return;
            }
            if (message.type !== "result" || !root.pending || message.id !== root.pending.request) return;
            var operation = root.pending; root.pending = null;
            if (!message.success) { root.error = message.error || "Task operation failed."; root.settled(); return; }
            root.error = "";
            if (operation.action === "load") {
                root.lists = message.result.lists || []; root.tasks = message.result.tasks || [];
                root.deletedLists = message.result.deletedLists || []; root.deletedTasks = message.result.deletedTasks || [];
                if (!root.lists.some(l => l.id === root.selectedList)) root.selectedList = "inbox";
                if (root.refreshPending) { root.refreshPending = false; root.load(); return; }
                root.settled(); return;
            }
            if (operation.action === "create-list") { root.selectedList = message.result.id; root.listCreated(operation.data.name); }
            else if (operation.action === "create-task") root.taskCreated(operation.data.title);
            else if (operation.action === "update") {
                if (operation.data.field === "deleted") root.lastDeleted = operation.data.value ? message.result : null;
                root.taskUpdated(operation.data.id, operation.data.field);
            } else if (operation.action === "set-details") {
                root.taskUpdated(operation.data.id, "title");
            } else if (operation.action === "resolve-alert") {
                root.taskUpdated(operation.data.id, "resolve-alert");
            } else if (operation.action === "update-list") {
                if (operation.data.field === "deleted") {
                    root.lastDeletedList = operation.data.value ? message.result : null;
                    root.selectedList = operation.data.value ? "inbox" : message.result.id;
                }
                root.listUpdated(operation.data.id, operation.data.field);
            }
            if (!root.load()) root.settled();
        }
    }
}

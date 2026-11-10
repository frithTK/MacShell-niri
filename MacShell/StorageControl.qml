import QtQuick
import Quickshell
import "Locale" as Language
import "SettingsSearch.js" as SettingsSearch
import "StorageState.js" as StorageState

Scope {
    id: root
    property var volumes: []
    property var folders: []
    property var large: []
    property var apps: []
    property var trash: ({})
    property int volumeId: 0
    property int scanId: 0
    property bool loading: false
    property bool scanning: false
    property int visited: 0
    property bool incomplete: false
    property bool cancelled: false
    property string reason: ""
    property int measuredAt: 0
    property int scanAt: 0
    property string method: ""
    property string lastError: ""
    readonly property bool ready: svc.ready
    readonly property string note: StorageState.scanNote({cancelled: cancelled, incomplete: incomplete, reason: reason}, (key, args) => Language.I18n.text(key, args))
    function formatBytes(value) { return StorageState.formatBytes(value); }
    function volumeLine(volume) { return StorageState.volumeLine(volume, (key, args) => Language.I18n.text(key, args)); }
    function folderTitle(id, name) { return StorageState.folderTitle(id, name, key => Language.I18n.text(key)); }
    function usedRatio(volume) { return StorageState.usedRatio(volume ? volume.used : -1, volume ? volume.total : -1); }

    function refresh() {
        if (!svc.ready) return -1;
        root.loading = true;
        root.volumeId = svc.send("volumes", {});
        return root.volumeId;
    }

    function scan() {
        if (!svc.ready) return -1;
        root.scanning = true;
        root.cancelled = false;
        root.visited = 0;
        root.lastError = "";
        root.scanId = svc.send("scan", {});
        if (root.scanId < 0) root.scanning = false;
        return root.scanId;
    }

    function cancel() {
        if (!svc.ready) return -1;
        return svc.send("cancel", {});
    }

    function reveal(path) {
        if (!SettingsSearch.isLocalPath(path)) return;
        Quickshell.execDetached(["xdg-open", path]);
    }

    function revealParent(path) {
        if (!SettingsSearch.isLocalPath(path)) return;
        var dir = SettingsSearch.parentDir(path);
        if (dir) Quickshell.execDetached(["xdg-open", dir]);
    }

    JsonService {
        id: svc
        launcher: "storage.sh"
        enabled: true
        onConnected: root.refresh()
        onReceived: message => {
            if (!message) return;
            if (message.type === "progress") {
                if (message.scanId === root.scanId) root.visited = Number(message.visited || 0);
                return;
            }
            if (message.type !== "result") return;
            if (message.id === root.volumeId && Array.isArray(message.volumes)) {
                root.volumes = message.volumes;
                root.measuredAt = Number(message.measuredAt || 0);
                root.loading = false;
                return;
            }
            if (message.id !== root.scanId) return;
            root.scanning = false;
            if (message.success === false) {
                root.lastError = String(message.error || "denied");
                return;
            }
            root.folders = Array.isArray(message.folders) ? message.folders : [];
            root.large = Array.isArray(message.large) ? message.large : [];
            root.apps = Array.isArray(message.apps) ? message.apps : [];
            root.trash = message.trash && typeof message.trash === "object" ? message.trash : {};
            root.incomplete = message.incomplete === true;
            root.cancelled = message.cancelled === true;
            root.reason = String(message.reason || "");
            root.visited = Number(message.visited || 0);
            root.scanAt = Number(message.measuredAt || 0);
            root.method = String(message.method || "");
        }
    }
}

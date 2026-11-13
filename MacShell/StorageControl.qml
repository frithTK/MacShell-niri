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
    property bool scanned: false
    property bool pendingScan: false
    property int visited: 0
    property bool incomplete: false
    property bool cancelled: false
    property string reason: ""
    property int measuredAt: 0
    property int scanAt: 0
    property string method: ""
    property string lastError: ""
    readonly property bool ready: svc.ready
    readonly property string helperError: svc.error
    readonly property var visibleVolumes: StorageState.primaryVolumes(volumes)
    readonly property string homePath: Quickshell.env("HOME") || ""
    readonly property var categorySegments: {
        var scanned = root.scanned;
        var folders = root.folders;
        var apps = root.apps;
        var trash = root.trash;
        var volumes = root.volumes;
        var home = root.homePath;
        return StorageState.volumeCategoriesByPath(volumes, {scanned: scanned, folders: folders, apps: apps, trash: trash}, home);
    }
    readonly property string note: StorageState.scanNote({cancelled: cancelled, incomplete: incomplete, reason: reason, scanned: scanned}, (key, args) => Language.I18n.text(key, args))
    function formatBytes(value) { return StorageState.formatBytes(value); }
    function volumeLine(volume) { return StorageState.volumeLine(volume, (key, args) => Language.I18n.text(key, args)); }
    function volumeTitle(volume) { return StorageState.volumeTitle(volume, key => Language.I18n.text(key)); }
    function folderTitle(id, name) { return StorageState.folderTitle(id, name, key => Language.I18n.text(key)); }
    function usedRatio(volume) { return StorageState.usedRatio(volume ? volume.used : -1, volume ? volume.total : -1); }
    function statusText(whenText) {
        return StorageState.statusText(root, (key, args) => Language.I18n.text(key, args), whenText);
    }
    function trashLine() {
        return StorageState.trashLine(trash, scanning, (key, args) => Language.I18n.text(key, args));
    }
    function trashPreview(items) {
        return StorageState.trashPreview(items, 8);
    }
    function asEntry(value) {
        if (!value || typeof value !== "object")
            return {};
        return {
            id: String(value.id || ""),
            name: String(value.name || ""),
            path: String(value.path || ""),
            bytes: Number(value.bytes),
            incomplete: value.incomplete === true
        };
    }
    function categoryTitle(id) {
        return StorageState.categoryTitle(id, key => Language.I18n.text(key));
    }
    function revealScript() {
        return decodeURIComponent(Qt.resolvedUrl("reveal-folder.sh").toString().replace(/^file:\/\//, ""));
    }

    function applyVolumes(message) {
        if (!message)
            return;
        root.volumes = StorageState.asList(message.volumes);
        if (message.measuredAt !== undefined && message.measuredAt !== null)
            root.measuredAt = Number(message.measuredAt || 0);
        if (message.method)
            root.method = String(message.method || "");
        root.loading = false;
        root.lastError = "";
    }

    function flushPendingScan() {
        if (!root.pendingScan || root.scanning)
            return;
        if (!svc.ready || svc.busy) {
            root.pendingScan = true;
            return;
        }
        root.pendingScan = false;
        root.scan();
    }

    function refresh() {
        if (!svc.ready || svc.busy) {
            if (!StorageState.asList(root.volumes).length)
                root.loading = true;
            return !svc.ready ? -1 : -2;
        }
        if (!StorageState.asList(root.volumes).length)
            root.loading = true;
        root.lastError = "";
        root.volumeId = svc.send("volumes", {});
        if (root.volumeId < 0)
            root.loading = false;
        return root.volumeId;
    }

    function scan() {
        if (!svc.ready)
            return -1;
        if (svc.busy) {
            root.pendingScan = true;
            return -2;
        }
        root.pendingScan = false;
        root.scanning = true;
        root.cancelled = false;
        root.visited = 0;
        root.lastError = "";
        root.scanId = svc.send("scan", {});
        if (root.scanId < 0)
            root.scanning = false;
        return root.scanId;
    }

    function scanIfNeeded() {
        if (root.scanning || root.scanned || root.cancelled)
            return -1;
        if (!svc.ready || svc.busy) {
            root.pendingScan = true;
            return -2;
        }
        return scan();
    }

    function cancel() {
        if (!svc.ready)
            return -1;
        return svc.send("cancel", {});
    }

    function reveal(path) {
        if (!SettingsSearch.isLocalPath(path))
            return;
        var uri = SettingsSearch.fileUri(path);
        if (!uri)
            return;
        Quickshell.execDetached(["sh", revealScript(), path, uri, "open"]);
    }

    function revealParent(path) {
        if (!SettingsSearch.isLocalPath(path))
            return;
        if (!SettingsSearch.parentDir(path))
            return;
        var uri = SettingsSearch.fileUri(path);
        if (!uri)
            return;
        Quickshell.execDetached(["sh", revealScript(), path, uri, "select"]);
    }

    JsonService {
        id: svc
        launcher: "storage.sh"
        enabled: true
        onConnected: {
            root.refresh();
            root.flushPendingScan();
        }
        onReceived: message => {
            if (!message)
                return;
            if (message.type === "progress") {
                if (Number(message.scanId) === Number(root.scanId))
                    root.visited = Number(message.visited || 0);
                return;
            }
            if (message.type !== "result")
                return;
            if (message.action === "volumes") {
                if (message.success === false) {
                    root.lastError = String(message.error || "denied");
                    root.loading = false;
                    root.flushPendingScan();
                    return;
                }
                root.applyVolumes(message);
                root.flushPendingScan();
                return;
            }
            if (message.action === "cancel" && (message.id === undefined || Number(message.id) === Number(root.scanId))) {
                root.scanning = false;
                root.cancelled = true;
                return;
            }
            if (message.action !== "scan")
                return;
            if (message.id !== undefined && Number(message.id) !== Number(root.scanId))
                return;
            root.scanning = false;
            root.loading = false;
            if (message.success === false) {
                root.lastError = String(message.error || "denied");
                return;
            }
            root.scanned = true;
            root.folders = StorageState.asList(message.folders);
            root.large = StorageState.asList(message.large);
            root.apps = StorageState.asList(message.apps);
            root.trash = root.asEntry(message.trash);
            root.incomplete = message.incomplete === true;
            root.cancelled = message.cancelled === true;
            root.reason = String(message.reason || "");
            root.visited = Number(message.visited || 0);
            root.scanAt = Number(message.measuredAt || 0);
            root.method = String(message.method || "");
            if (message.volumes !== undefined)
                root.applyVolumes(message);
        }
    }
}

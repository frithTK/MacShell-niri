import QtQuick
import Quickshell
import "Locale" as Language
import "SettingsSearch.js" as SettingsSearch

Scope {
    id: root
    property var cache: ({})
    property var pending: ({})
    property var wanted: ({})
    property bool applying: false
    property int applyId: 0
    property string applyAppId: ""
    property string applyOp: ""
    readonly property bool ready: svc.ready
    signal resolved(string appId, var source)
    signal applied(bool ok, string error, string op, string appId)

    function normalize(id) {
        return String(id || "").replace(/\.desktop$/i, "").trim();
    }

    function sourceOf(appId) {
        var id = root.normalize(appId);
        return id && root.cache[id] ? root.cache[id] : null;
    }

    function request(appId) {
        var id = root.normalize(appId);
        if (!id) return;
        var want = {};
        for (var key in root.wanted) want[key] = root.wanted[key];
        want[id] = true;
        root.wanted = want;
        if (root.cache[id]) {
            root.resolved(id, root.cache[id]);
            return;
        }
        if (root.pending[id] || !svc.ready) return;
        var next = {};
        for (var wait in root.pending) next[wait] = root.pending[wait];
        next[id] = true;
        root.pending = next;
        svc.send("resolve", { id: id });
    }

    function flushWanted() {
        if (!svc.ready) return;
        for (var id in root.wanted) {
            if (root.cache[id] || root.pending[id]) continue;
            var next = {};
            for (var wait in root.pending) next[wait] = root.pending[wait];
            next[id] = true;
            root.pending = next;
            svc.send("resolve", { id: id });
        }
    }

    function showInfo(name, source) {
        var lines = [];
        if (source) {
            if (source.name) lines.push(String(source.name));
            if (source.origin) lines.push(String(source.origin));
            if (source.path) lines.push(String(source.path));
            if (source.package) lines.push(String(source.package) + (source.version ? " " + source.version : ""));
            if (source.repo) lines.push(String(source.repo));
            if (source.flatpakId) lines.push(String(source.flatpakId));
        }
        Quickshell.execDetached(["notify-send", "-a", "MacShell", name || "Application", lines.join("\n") || "Identifying source…"]);
    }

    function reveal(source) {
        var path = source && source.path;
        if (!SettingsSearch.isLocalPath(path)) return;
        var dir = SettingsSearch.parentDir(path);
        if (!dir) return;
        Quickshell.execDetached(["xdg-open", dir]);
    }

    function forget(appId) {
        var id = root.normalize(appId);
        if (!id || !root.cache[id]) return;
        var cache = {};
        for (var key in root.cache) if (key !== id) cache[key] = root.cache[key];
        root.cache = cache;
    }

    function apply(appId, op, source) {
        var id = root.normalize(appId);
        if (!id || !op || !source) return -3;
        if (root.applying) {
            root.applied(false, "busy", op, id);
            return -2;
        }
        if (!svc.ready) return -1;
        root.applying = true;
        root.applyAppId = id;
        root.applyOp = op;
        root.applyId = svc.send("apply", {
            id: id,
            op: op,
            origin: source.origin || "",
            path: source.path || "",
            package: source.package || source.flatpakId || ""
        });
        if (root.applyId < 0) {
            root.applying = false;
            root.applied(false, "busy", op, id);
        }
        return root.applyId;
    }

    JsonService {
        id: svc
        launcher: "desktop-source.sh"
        enabled: true
        onConnected: root.flushWanted()
        onReceived: message => {
            if (!message || message.type !== "result") return;
            if (root.applying && message.id === root.applyId) {
                var appId = root.applyAppId;
                var op = root.applyOp;
                var ok = message.success === true;
                var error = ok ? "" : String(message.error || "Package operation failed");
                root.applying = false;
                root.applyId = 0;
                root.applyAppId = "";
                root.applyOp = "";
                root.forget(appId);
                root.request(appId);
                var body = ok ? Language.I18n.text("appmenu.apply_done")
                              : (error === "busy" ? Language.I18n.text("appmenu.apply_busy")
                              : (error === "Source changed" ? Language.I18n.text("appmenu.source_changed")
                              : (error ? error : Language.I18n.text("appmenu.apply_failed"))));
                Quickshell.execDetached(["notify-send", "-a", "MacShell", appId || "Application", body]);
                root.applied(ok, error, op, appId);
                return;
            }
            if (!message.source) return;
            var source = message.source;
            var id = root.normalize(source.appId);
            if (!id) return;
            var cache = {};
            for (var key in root.cache) cache[key] = root.cache[key];
            cache[id] = source;
            root.cache = cache;
            var pending = {};
            for (var wait in root.pending) if (wait !== id) pending[wait] = root.pending[wait];
            root.pending = pending;
            root.resolved(id, source);
        }
    }
}

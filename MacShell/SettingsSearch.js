.pragma library

// Spotlight matching for Settings panes. Query length 2+; rank exact, prefix, then keywords.

function normalize(query) {
    return String(query || "").trim().toLowerCase();
}

function score(pane, query) {
    if (!pane || !query) return 0;
    var id = String(pane.id || "").toLowerCase();
    var name = String(pane.name || "").toLowerCase();
    var searchName = String(pane.searchName || "").toLowerCase();
    var keys = String(pane.keys || "").toLowerCase();
    if (id === query || name === query || searchName === query) return 100;
    if (name.indexOf(query) === 0 || searchName.indexOf(query) === 0 || id.indexOf(query) === 0)
        return 80;
    if (name.indexOf(query) >= 0 || searchName.indexOf(query) >= 0) return 60;
    if (keys.indexOf(query) >= 0) return 40;
    if (id.indexOf(query) >= 0) return 20;
    return 0;
}

function match(panes, query) {
    var q = normalize(query);
    if (q.length < 2 || !panes || panes.length === 0) return [];
    var hits = [];
    for (var i = 0; i < panes.length; i++) {
        var value = score(panes[i], q);
        if (value > 0) hits.push({ pane: panes[i], score: value, index: i });
    }
    hits.sort(function (a, b) {
        if (b.score !== a.score) return b.score - a.score;
        return a.index - b.index;
    });
    var out = [];
    for (var j = 0; j < hits.length; j++) out.push(hits[j].pane);
    return out;
}

function indexOf(panes, id) {
    if (!panes) return -1;
    for (var i = 0; i < panes.length; i++) {
        if (panes[i].id === id) return i;
    }
    return -1;
}

function openTarget(panes, current, id, enabled) {
    if (!enabled) return { ok: false, reason: "disabled", index: current };
    var index = indexOf(panes, id);
    if (index < 0) return { ok: false, reason: "missing", index: current };
    return { ok: true, reason: "", index: index, same: index === current };
}

function actionsFor(kind) {
    if (kind === "file") return ["open", "reveal", "copyPath"];
    if (kind === "app") return ["open", "pin", "reveal", "info"];
    if (kind === "window") return ["focus"];
    if (kind === "settings") return ["open"];
    if (kind === "action") return ["run"];
    return ["open"];
}

function extras(kind) {
    if (kind === "file") return ["reveal", "copyPath", "preview"];
    if (kind === "app") return ["pin", "reveal", "info"];
    return [];
}

function hasExtras(kind) {
    return extras(kind).length > 0;
}

function isLocalPath(path) {
    if (typeof path !== "string" || path.length === 0) return false;
    if (path.charAt(0) !== "/") return false;
    if (path.indexOf("\0") >= 0 || path.indexOf("\n") >= 0 || path.indexOf("\r") >= 0)
        return false;
    return true;
}

function fileUri(path) {
    if (!isLocalPath(path)) return "";
    var parts = path.split("/");
    var out = [];
    for (var i = 0; i < parts.length; i++)
        out.push(encodeURIComponent(parts[i]));
    return "file://" + out.join("/");
}

function parentDir(path) {
    if (!isLocalPath(path) || path === "/") return "";
    var trimmed = path.length > 1 && path.charAt(path.length - 1) === "/"
        ? path.substring(0, path.length - 1) : path;
    var slash = trimmed.lastIndexOf("/");
    if (slash < 0) return "";
    if (slash === 0) return "/";
    return trimmed.substring(0, slash);
}

function describe(kind, item) {
    var rows = [{ id: "open", enabled: true, reason: "", close: true }];
    if (kind === "file") {
        var path = item && item.path;
        var local = isLocalPath(path);
        var parent = local ? parentDir(path) : "";
        rows.push({ id: "reveal", enabled: parent !== "", reason: parent !== "" ? "" : "missing", close: true });
        rows.push({ id: "copyPath", enabled: local, reason: local ? "" : "missing", close: false });
        rows.push({ id: "preview", enabled: local, reason: local ? "" : "missing", close: false });
    } else if (kind === "app") {
        var appPath = item && item.path;
        var appLocal = isLocalPath(appPath);
        var appParent = appLocal ? parentDir(appPath) : "";
        rows.push({ id: "pin", enabled: true, reason: "", close: true });
        rows.push({ id: "reveal", enabled: appParent !== "", reason: appParent !== "" ? "" : "unavailable", close: true });
        rows.push({ id: "info", enabled: true, reason: "", close: false });
    }
    return rows;
}

function appendGroup(out, items, limit, groupLimit) {
    var n = 0;
    var maxGroup = groupLimit > 0 ? groupLimit : limit;
    for (var i = 0; i < items.length && out.length < limit && n < maxGroup; i++) {
        out.push(items[i]);
        n++;
    }
    return out;
}

.pragma library

// Spotlight matching for Settings panes. Query length 2+; rank exact, prefix, then keywords.

function normalize(query) {
    return String(query || "").trim().toLowerCase();
}

// Settings that live inside a page. `label` is a catalog id; the caller translates it.
var controls = [
    { label: "network.hotspot", pane: "network", anchor: "hotspot", keys: "hotspot ap share wifi точка доступа хотспот раздача" },
    { label: "network.vpn", pane: "network", anchor: "vpn", keys: "vpn wireguard openvpn туннель" },
    { label: "network.proxy", pane: "network", anchor: "proxy", keys: "proxy pac socks http https прокси" },
    { label: "ui.t_681e12098d28", pane: "wifi", anchor: "", keys: "ethernet lan кабель проводная" },
    { label: "security.fingerprint", pane: "security", anchor: "", keys: "fingerprint biometric отпечаток палец биометрия" },
    { label: "ui.t_d9a2bf53437c", pane: "displays", anchor: "", keys: "night shift warm ночной режим ночная смена" },
    { label: "battery.health", pane: "battery", anchor: "", keys: "battery health charge аккумулятор износ состояние" }
];

function words(query) {
    var q = normalize(query);
    if (q.length < 2) return [];
    return q.split(/\s+/).filter(function (word) { return word.length >= 2; });
}

function covers(text, list) {
    var hay = String(text || "").toLowerCase();
    for (var i = 0; i < list.length; i++)
        if (hay.indexOf(list[i]) < 0) return false;
    return list.length > 0;
}

function score(pane, query) {
    if (!pane) return 0;
    var q = normalize(query);
    var list = words(q);
    if (!list.length) return 0;
    var id = String(pane.id || "").toLowerCase();
    var name = String(pane.name || "").toLowerCase();
    var searchName = String(pane.searchName || "").toLowerCase();
    var keys = String(pane.keys || "").toLowerCase();
    if (id === q || name === q || searchName === q) return 100;
    if (name.indexOf(q) === 0 || searchName.indexOf(q) === 0 || id.indexOf(q) === 0)
        return 80;
    if (covers(name + " " + searchName, list)) return 70;
    if (name.indexOf(q) >= 0 || searchName.indexOf(q) >= 0) return 60;
    if (covers(keys + " " + id, list)) return 40;
    if (id.indexOf(q) >= 0) return 20;
    return 0;
}

function paneById(panes, id) {
    if (!panes) return null;
    for (var i = 0; i < panes.length; i++)
        if (panes[i] && panes[i].id === id) return panes[i];
    return null;
}

function matchControls(panes, query, translate, english) {
    var list = words(query);
    if (!list.length) return [];
    var tr = translate || function (key) { return key; };
    var en = english || tr;
    var q = normalize(query);
    var hits = [];
    for (var i = 0; i < controls.length; i++) {
        var entry = controls[i];
        var label = String(tr(entry.label) || "");
        var englishLabel = String(en(entry.label) || "");
        var keys = String(entry.keys || "");
        if (!covers(label + " " + englishLabel + " " + keys, list)) continue;
        var rank = 40;
        if (normalize(label) === q || normalize(englishLabel) === q) rank = 100;
        else if (normalize(label).indexOf(q) === 0 || normalize(englishLabel).indexOf(q) === 0) rank = 80;
        else if (covers(label + " " + englishLabel, list)) rank = 70;
        var pane = paneById(panes, entry.pane);
        hits.push({
            id: entry.label,
            pane: entry.pane,
            anchor: entry.anchor || "",
            label: label,
            paneName: pane ? String(pane.name || "") : "",
            score: rank,
            index: i
        });
    }
    hits.sort(function (a, b) {
        if (b.score !== a.score) return b.score - a.score;
        return a.index - b.index;
    });
    return hits;
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

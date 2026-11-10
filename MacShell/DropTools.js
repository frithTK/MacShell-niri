.pragma library
.import "QuickLook.js" as QuickLook
.import "SettingsSearch.js" as SettingsSearch

var MAX_FILES = 8;

function parseUriList(text) {
    var lines = String(text || "").split(/\r?\n/);
    var out = [];
    for (var i = 0; i < lines.length; i++) {
        var line = String(lines[i] || "").trim();
        if (!line || line.charAt(0) === "#")
            continue;
        var local = QuickLook.localPath(line);
        if (!local || out.indexOf(local) >= 0)
            continue;
        out.push(local);
        if (out.length >= MAX_FILES)
            break;
    }
    return out;
}

function localPaths(values) {
    var out = [];
    var list = values || [];
    for (var i = 0; i < list.length; i++) {
        var local = QuickLook.localPath(list[i]);
        if (!local || out.indexOf(local) >= 0)
            continue;
        out.push(local);
        if (out.length >= MAX_FILES)
            break;
    }
    return out;
}

function commonActions(files) {
    if (!files || files.length === 0)
        return [];
    var first = (files[0] && files[0].actions) || [];
    var out = [];
    for (var i = 0; i < first.length; i++) {
        var action = first[i];
        if (!action || !action.id)
            continue;
        var ok = true;
        for (var j = 0; j < files.length; j++) {
            var rows = (files[j] && files[j].actions) || [];
            var match = null;
            for (var k = 0; k < rows.length; k++) {
                if (rows[k].id === action.id) {
                    match = rows[k];
                    break;
                }
            }
            if (!match || match.available === false) {
                ok = false;
                break;
            }
        }
        if (ok)
            out.push({ id: action.id, available: true, missing: "" });
    }
    return out;
}

function firstAvailable(actions) {
    var rows = actions || [];
    for (var i = 0; i < rows.length; i++) {
        if (rows[i] && rows[i].available !== false)
            return i;
    }
    return 0;
}

function nextIndex(actions, current, delta) {
    var rows = actions || [];
    var n = rows.length;
    if (n === 0)
        return 0;
    var step = delta >= 0 ? 1 : -1;
    var index = ((Number(current) || 0) % n + n) % n;
    for (var i = 0; i < n; i++) {
        index = (index + step + n) % n;
        if (rows[index] && rows[index].available !== false)
            return index;
    }
    return ((Number(current) || 0) % n + n) % n;
}

function dests(results) {
    var out = [];
    var rows = results || [];
    for (var i = 0; i < rows.length; i++) {
        if (rows[i] && rows[i].success && rows[i].dest)
            out.push(rows[i].dest);
    }
    return out;
}

function resultKey(payload) {
    if (!payload)
        return "droptools.failed";
    if (payload.cancelled)
        return "droptools.cancelled";
    if (payload.partial)
        return "droptools.partial";
    if (Number(payload.ok) > 0 && Number(payload.failed) === 0)
        return "droptools.done";
    return "droptools.failed";
}

function errorKey(code) {
    if (code === "missing") return "droptools.missing";
    if (code === "denied") return "droptools.denied";
    if (code === "too_large") return "droptools.too_large";
    if (code === "invalid") return "droptools.invalid";
    if (code === "decode") return "droptools.decode";
    if (code === "encode") return "droptools.encode";
    if (code === "pdftoppm") return "droptools.missing_pdftoppm";
    if (code === "unsupported") return "droptools.unsupported";
    if (code === "limit") return "droptools.limit";
    if (code === "name_conflict") return "droptools.name_conflict";
    if (code === "cancelled") return "droptools.cancelled";
    if (code === "missing_tool") return "droptools.missing_tool";
    return "droptools.failed";
}

function actionKey(id) {
    if (id === "png") return "droptools.png";
    if (id === "jpeg") return "droptools.jpeg";
    if (id === "pdf") return "droptools.pdf";
    if (id === "rotate90") return "droptools.rotate90";
    if (id === "pdf-png") return "droptools.pdf_png";
    if (id === "pdf-jpeg") return "droptools.pdf_jpeg";
    return "droptools.convert";
}

function isLocalPath(path) {
    return SettingsSearch.isLocalPath(path);
}

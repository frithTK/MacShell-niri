.pragma library

function normalizeId(id) {
    return String(id || "").replace(/\.desktop$/i, "").trim();
}

function originOf(source) {
    return source && source.origin ? String(source.origin) : "";
}

function packageSupported(source) {
    if (!source || source.unique === false) return false;
    var origin = originOf(source);
    if (origin === "pacman") return true;
    return origin === "flatpak-user" || origin === "flatpak-system";
}

function packageSummary(source) {
    if (!source) return "";
    var parts = [];
    if (source.package) parts.push(String(source.package));
    else if (source.flatpakId) parts.push(String(source.flatpakId));
    if (source.repo) parts.push(String(source.repo));
    if (source.version) parts.push(String(source.version));
    if (originOf(source) === "flatpak-user") parts.push("user");
    if (originOf(source) === "flatpak-system") parts.push("system");
    return parts.join(" · ");
}

function confirmKind(id, source) {
    if (id === "update" && originOf(source) === "pacman") return "update_system";
    return id;
}

function reasonFor(source, id) {
    if (!source) return "pending";
    var ops = source.operations || {};
    var reasons = ops.reasons || {};
    if (id === "reveal") {
        if (source.path && source.unique !== false) return "";
        if (originOf(source) === "ambiguous") return "ambiguous";
        if (originOf(source) === "builtin") return "builtin";
        if (originOf(source) === "missing") return "missing";
        return "unavailable";
    }
    if (id === "info") {
        if (originOf(source) && originOf(source) !== "missing") return "";
        return originOf(source) === "missing" ? "missing" : "pending";
    }
    if (id === "remove" || id === "reinstall" || id === "update") {
        if (reasons[id]) return String(reasons[id]);
        if (originOf(source) === "ambiguous" || source.unique === false) return "ambiguous";
        if (originOf(source) === "builtin") return "builtin";
        if (originOf(source) === "local") return "local";
        if (originOf(source) === "system") return "unowned";
        if (originOf(source) === "pacman" && source.official !== true) return "unofficial";
        if (originOf(source) === "pacman" && id === "reinstall") return "system-update";
        return "confirm";
    }
    return "";
}

function packageIds(source) {
    if (!packageSupported(source)) return [];
    if (originOf(source) === "pacman") {
        var ids = [];
        if (!source.operations || source.operations.remove) ids.push("remove");
        if (source.official === true) ids.push("update");
        return ids;
    }
    return ["remove", "reinstall", "update"];
}

function actions(spec) {
    spec = spec || {};
    var source = spec.source || null;
    var rows = [];
    rows.push({ id: "open", enabled: spec.hasEntry !== false, reason: "", close: true });
    rows.push({ id: "pin", enabled: true, reason: "", close: true, pinned: spec.pinned === true });
    var revealReason = reasonFor(source, "reveal");
    rows.push({ id: "reveal", enabled: revealReason === "", reason: revealReason, close: true });
    var infoReason = reasonFor(source, "info");
    rows.push({ id: "info", enabled: infoReason === "", reason: infoReason, close: false });
    var pkgs = packageIds(source);
    if (pkgs.length > 0) {
        rows.push({ id: "sep" });
        for (var i = 0; i < pkgs.length; i++) {
            var reason = reasonFor(source, pkgs[i]);
            var allowed = reason === "confirm";
            if (spec.applying === true && allowed) {
                allowed = false;
                reason = "busy";
            }
            rows.push({
                id: pkgs[i],
                enabled: allowed,
                reason: allowed ? "" : reason,
                close: true,
                confirm: allowed,
                confirmKind: confirmKind(pkgs[i], source),
                summary: packageSummary(source)
            });
        }
    }
    return rows;
}

function ids(rows) {
    var out = [];
    for (var i = 0; i < rows.length; i++) out.push(rows[i].id);
    return out;
}

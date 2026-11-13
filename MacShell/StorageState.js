.pragma library

function bytes(value) {
    return typeof value === "number" && isFinite(value) && value >= 0 ? value : -1;
}

function asList(value) {
    if (value === undefined || value === null)
        return [];
    if (Array.isArray(value))
        return value.slice();
    if (typeof value === "object" && typeof value.length === "number" && value.length >= 0) {
        var rows = [];
        for (var i = 0; i < value.length; i++)
            rows.push(value[i]);
        return rows;
    }
    return [];
}

function formatBytes(value) {
    var n = bytes(value);
    if (n < 0) return "";
    var units = ["B", "KiB", "MiB", "GiB", "TiB"];
    var i = 0;
    while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
    var shown = i === 0 ? String(Math.round(n)) : (n >= 10 ? String(Math.round(n)) : (Math.round(n * 10) / 10).toFixed(1));
    return shown + " " + units[i];
}

function usedRatio(used, total) {
    var u = bytes(used), t = bytes(total);
    if (u < 0 || t <= 0) return 0;
    return Math.max(0, Math.min(1, u / t));
}

function formatPercent(used, total) {
    return String(Math.round(usedRatio(used, total) * 100));
}

function volumeLine(volume, translate) {
    if (!volume) return "";
    if (volume.ready === false)
        return translate ? translate("storage.unavailable") : "Unavailable";
    var used = formatBytes(volume.used), total = formatBytes(volume.total), free = formatBytes(volume.available);
    if (!used || !total) return "";
    var percent = formatPercent(volume.used, volume.total);
    return translate
        ? translate("storage.volume_line", {used: used, total: total, free: free, percent: percent})
        : used + " of " + total + " · " + percent + "% · " + free + " free";
}

function volumeTitle(volume, translate) {
    if (!volume) return "";
    var path = String(volume.path || "");
    var key = path === "/" ? "storage.volume_system"
        : path === "/home" ? "storage.volume_home"
        : (path === "/boot/efi" || path === "/efi" || path === "/boot") ? "storage.volume_efi"
        : "";
    if (key && translate) {
        var text = translate(key);
        if (text && text !== key) return text;
    }
    return volume.name || path;
}

function primaryVolumes(volumes) {
    var rows = [];
    var list = asList(volumes);
    for (var i = 0; i < list.length; ++i) {
        if (list[i] && list[i].bind !== true && list[i].bind !== "true")
            rows.push(list[i]);
    }
    return rows;
}

function statusText(state, translate, whenText) {
    if (!state)
        return translate ? translate("storage.unavailable") : "Unavailable";
    var hasVolumes = asList(state.volumes).length > 0;
    if (state.helperError && !state.ready && !hasVolumes)
        return translate ? translate("storage.helper_missing") : "Storage helper is missing or incompatible";
    if (!hasVolumes && !state.scanned && (state.loading || !state.ready))
        return translate ? translate("storage.loading") : "Reading volume sizes…";
    if (state.measuredAt && whenText)
        return translate ? translate("storage.measured", {when: whenText}) : whenText;
    return "";
}

function folderTitle(id, name, translate) {
    if (!id) return name || "";
    var key = "storage.folder_" + id;
    if (!translate) return name || id;
    var text = translate(key);
    return text && text !== key ? text : (name || id);
}

function scanNote(report, translate) {
    if (!report) return "";
    if (report.cancelled) return translate ? translate("storage.cancelled") : "Scan cancelled";
    if (report.incomplete && report.reason === "limit")
        return translate ? translate("storage.incomplete_limit") : "Stopped after a visit limit. This is not a full disk map.";
    if (report.incomplete && report.reason === "denied")
        return translate ? translate("storage.incomplete_denied") : "Some folders could not be read. This is not a full disk map.";
    if (report.incomplete)
        return translate ? translate("storage.incomplete") : "This listing is incomplete and is not a full disk map.";
    if (!report.scanned)
        return "";
    return translate ? translate("storage.method_note") : "Folder sizes are apparent file sizes, not allocated disk blocks. Hard links count once; other mounts are skipped.";
}

function foldersAreNotVolume(folders, volume) {
    var sum = 0;
    var list = asList(folders);
    for (var i = 0; i < list.length; ++i) sum += Math.max(0, Number(list[i].bytes) || 0);
    var used = volume && typeof volume.used === "number" ? volume.used : 0;
    return used <= 0 || sum !== used;
}

function categoryHostPath(volumes, home) {
    var rows = primaryVolumes(volumes);
    var homePath = String(home || "");
    var best = "";
    for (var i = 0; i < rows.length; i++) {
        var path = String(rows[i] && rows[i].path || "");
        if (path === "/") {
            if (!best) best = "/";
            continue;
        }
        if (homePath === path || homePath.indexOf(path + "/") === 0) {
            if (path.length > best.length)
                best = path;
        }
    }
    return best || "/";
}

function categoryTitle(id, translate) {
    var key = "storage.category_" + String(id || "");
    if (!translate) {
        if (id === "apps") return "Apps";
        if (id === "photos") return "Photos";
        if (id === "videos") return "Videos";
        if (id === "documents") return "Documents";
        if (id === "downloads") return "Downloads";
        if (id === "music") return "Music";
        if (id === "desktop") return "Desktop";
        if (id === "cache") return "Cache";
        if (id === "trash") return "Trash";
        if (id === "system") return "System";
        if (id === "other") return "Other";
        return String(id || "");
    }
    var text = translate(key);
    return text && text !== key ? text : String(id || "");
}

function folderBytes(folders, ids) {
    var sum = 0;
    var list = asList(folders);
    for (var i = 0; i < list.length; i++) {
        var id = list[i] && list[i].id;
        if (ids.indexOf(id) < 0)
            continue;
        sum += Math.max(0, Number(list[i].bytes) || 0);
    }
    return sum;
}

function entryBytes(entry) {
    if (!entry)
        return 0;
    var n = Number(entry.bytes);
    return isFinite(n) && n > 0 ? n : 0;
}

function volumeCategories(volume, state) {
    if (!volume || volume.ready === false || !state || !state.scanned)
        return [];
    var used = bytes(volume.used);
    var total = bytes(volume.total);
    if (used < 0 || total <= 0)
        return [];
    var appRows = asList(state.apps);
    var apps = 0;
    for (var i = 0; i < appRows.length; i++)
        apps += entryBytes(appRows[i]);
    var values = {
        apps: apps,
        photos: folderBytes(state.folders, ["pictures"]),
        videos: folderBytes(state.folders, ["videos"]),
        documents: folderBytes(state.folders, ["documents"]),
        downloads: folderBytes(state.folders, ["downloads"]),
        music: folderBytes(state.folders, ["music"]),
        desktop: folderBytes(state.folders, ["desktop"]),
        cache: folderBytes(state.folders, ["cache"]),
        trash: entryBytes(state.trash),
        other: folderBytes(state.folders, ["public", "templates"])
    };
    var order = ["apps", "photos", "videos", "documents", "downloads", "music", "desktop", "trash", "cache", "other"];
    var measured = 0;
    for (var m = 0; m < order.length; m++)
        measured += values[order[m]];
    if (measured > used && measured > 0) {
        var scale = used / measured;
        for (var s = 0; s < order.length; s++)
            values[order[s]] = Math.floor(values[order[s]] * scale);
        measured = 0;
        for (var r = 0; r < order.length; r++)
            measured += values[order[r]];
    }
    values.system = Math.max(0, used - measured);
    order.push("system");
    var colors = {
        apps: "#0A84FF",
        photos: "#FFD60A",
        videos: "#FF375F",
        documents: "#30D158",
        downloads: "#64D2FF",
        music: "#BF5AF2",
        desktop: "#32ADE6",
        trash: "#FF9F0A",
        cache: "#636366",
        other: "#AC8E68",
        system: "#8E8E93"
    };
    var rows = [];
    for (var c = 0; c < order.length; c++) {
        var id = order[c];
        var n = values[id];
        if (n <= 0)
            continue;
        rows.push({ id: id, bytes: n, ratio: n / total, color: colors[id] });
    }
    return rows;
}

function volumeCategoriesByPath(volumes, state, home) {
    var rows = primaryVolumes(volumes);
    var host = categoryHostPath(volumes, home);
    var out = {};
    for (var i = 0; i < rows.length; i++) {
        var volume = rows[i];
        var path = String(volume && volume.path || "");
        out[path] = path === host ? volumeCategories(volume, state) : [];
    }
    return out;
}

function trashPreview(items, limit) {
    var rows = asList(items);
    var max = typeof limit === "number" && limit > 0 ? limit : 8;
    return rows.slice(0, max);
}

function trashLine(trash, scanning, translate) {
    var n = trash ? Number(trash.bytes) : NaN;
    if (isFinite(n) && n >= 0)
        return formatBytes(n);
    if (scanning)
        return translate ? translate("storage.scanning", {count: 0}) : "Scanning…";
    return translate ? translate("storage.scan_needed") : "Scan to measure";
}

.pragma library

function bytes(value) {
    return typeof value === "number" && isFinite(value) && value >= 0 ? value : -1;
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

function volumeLine(volume, translate) {
    if (!volume) return "";
    if (volume.ready === false)
        return translate ? translate("storage.unavailable") : "Unavailable";
    var used = formatBytes(volume.used), total = formatBytes(volume.total), free = formatBytes(volume.available);
    if (!used || !total) return "";
    return translate
        ? translate("storage.volume_line", {used: used, total: total, free: free})
        : used + " of " + total + " (" + free + " free)";
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
    return translate ? translate("storage.method_note") : "Folder sizes are apparent file sizes, not allocated disk blocks. Hard links count once; other mounts are skipped.";
}

function foldersAreNotVolume(folders, volume) {
    var sum = 0;
    for (var i = 0; folders && i < folders.length; ++i) sum += Math.max(0, Number(folders[i].bytes) || 0);
    var used = volume && typeof volume.used === "number" ? volume.used : 0;
    return used <= 0 || sum !== used;
}

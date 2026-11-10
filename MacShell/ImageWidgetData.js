.pragma library

function validSettings(value) {
    if (!value || typeof value !== "object" || Array.isArray(value)) return false;
    var path = value.path === undefined ? "" : value.path;
    if (typeof path !== "string" || path.length > 4096 || /[\u0000-\u001f]/.test(path)) return false;
    var lower = path.trim().toLowerCase();
    return lower.indexOf("http:") !== 0 && lower.indexOf("https:") !== 0 && lower.indexOf("ftp:") !== 0;
}
function path(value) { return validSettings(value) ? String(value.path || "").trim() : ""; }
function source(value) {
    var local = path(value);
    if (!local) return "";
    if (local.indexOf("file://") === 0) {
        var rest = local.slice(7);
        return rest.indexOf("/") === 0 ? "file://" + rest : "";
    }
    return local.indexOf("/") === 0 ? "file://" + local : "";
}

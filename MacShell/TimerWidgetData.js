.pragma library

var defaults = [5, 15, 25];
function validSettings(value) {
    if (!value || typeof value !== "object" || Array.isArray(value)) return false;
    var presets = value.presets === undefined ? defaults : value.presets;
    return Array.isArray(presets) && presets.length === 3 && presets.every(minutes =>
        typeof minutes === "number" && isFinite(minutes) && Math.floor(minutes) === minutes && minutes >= 1 && minutes <= 1440);
}
function presets(value) { return validSettings(value) ? (value.presets || defaults) : defaults; }
function duration(ms) {
    var seconds = Math.max(0, Math.ceil(ms / 1000));
    var h = Math.floor(seconds / 3600), m = Math.floor(seconds / 60) % 60, s = seconds % 60;
    function pad(n) { return n < 10 ? "0" + n : String(n); }
    return h ? h + ":" + pad(m) + ":" + pad(s) : pad(m) + ":" + pad(s);
}

.pragma library

function pad(value) { return String(value).padStart(2, "0"); }
function format(value) {
    if (value === null || value === undefined) return "";
    var d = new Date(value);
    if (isNaN(d.getTime())) return "";
    return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate()) + " " + pad(d.getHours()) + ":" + pad(d.getMinutes());
}
function parse(value, previous) {
    var raw = String(value || "").trim();
    if (!raw) return {ok: true, value: null};
    // Keep an existing instant unchanged, including one in an ambiguous hour.
    if (previous !== null && previous !== undefined && raw === format(previous)) return {ok: true, value: previous};
    var match = /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2})$/.exec(raw);
    if (!match) return {ok: false, error: "invalid"};
    var y = +match[1], m = +match[2], d = +match[3], h = +match[4], minute = +match[5];
    if (y < 1970 || m < 1 || m > 12 || h > 23 || minute > 59) return {ok: false, error: "invalid"};
    var date = new Date(y, m - 1, d, h, minute, 0, 0);
    if (date.getFullYear() !== y || date.getMonth() !== m - 1 || date.getDate() !== d || date.getHours() !== h || date.getMinutes() !== minute)
        return {ok: false, error: "invalid"};
    var timestamp = date.getTime();
    if (timestamp < 0 || timestamp > 253402300799999) return {ok: false, error: "invalid"};
    // A repeated wall-clock minute has two distinct instants; refuse to guess.
    for (var offset = 1; offset <= 180; offset++) {
        if (format(timestamp - offset * 60000) === raw || format(timestamp + offset * 60000) === raw)
            return {ok: false, error: "ambiguous"};
    }
    return {ok: true, value: timestamp};
}

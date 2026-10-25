.pragma library

function number(text) {
    var value = String(text).trim();
    return /^\d+$/.test(value) ? Number(value) : NaN;
}
function fraction(current, maximum) {
    return isFinite(current) && isFinite(maximum) && current >= 0 && maximum > 0 && current <= maximum
        ? Math.round(current / maximum * 100) / 100 : NaN;
}
function device(text) {
    var fields = String(text).trim().split("\n")[0].split(",");
    if (fields.length !== 5 || !/^[a-zA-Z0-9_: .+-]+$/.test(fields[0]) || fields[0] === "." || fields[0] === ".."
        || ["backlight", "leds"].indexOf(fields[1]) < 0) return null;
    var current = number(fields[2]), maximum = number(fields[4]), value = fraction(current, maximum);
    return isFinite(value) ? {path: fields[1] + "/" + fields[0], current: current, maximum: maximum, value: value} : null;
}

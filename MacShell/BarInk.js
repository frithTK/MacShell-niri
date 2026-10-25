.pragma library

function luminance(r, g, b) {
    function linear(v) { return v <= .04045 ? v / 12.92 : Math.pow((v + .055) / 1.055, 2.4); }
    return .2126 * linear(r) + .7152 * linear(g) + .0722 * linear(b);
}
function preferLight(r, g, b, previous) {
    var value = luminance(r, g, b), light = 1.05 / (value + .05), dark = (value + .05) / .05;
    // Avoid oscillation when the bar's own small glyphs tip a near-grey sample.
    if (previous === true && dark < light * 1.2) return true;
    if (previous === false && light < dark * 1.2) return false;
    return light > dark;
}

.pragma library

// Named glass looks for Appearance. Blur stays below 8 so the shader
// keeps a full-resolution backdrop; the raw sliders remain for fine tuning.
var PRESETS = [
    {id: "clear", blur: 3, opacity: 0.16, liquid: 0.5, rim: 0.35, grain: 0.01},
    {id: "standard", blur: 5, opacity: 0.42, liquid: 1.0, rim: 0.45, grain: 0.03},
    {id: "vibrant", blur: 7, opacity: 0.24, liquid: 1.35, rim: 0.6, grain: 0.02},
    {id: "frosted", blur: 7, opacity: 0.62, liquid: 0.75, rim: 0.4, grain: 0.04}
];

function count() {
    return PRESETS.length;
}

function at(index) {
    var i = Math.max(0, Math.min(PRESETS.length - 1, Math.round(index)));
    return PRESETS[i];
}

function byId(id) {
    for (var i = 0; i < PRESETS.length; i++) {
        if (PRESETS[i].id === id)
            return PRESETS[i];
    }
    return null;
}

function ids() {
    var names = [];
    for (var i = 0; i < PRESETS.length; i++)
        names.push(PRESETS[i].id);
    return names;
}

function close(a, b, eps) {
    return Math.abs(Number(a) - Number(b)) <= eps;
}

function matchIndex(blur, opacity, liquid, rim, grain) {
    for (var i = 0; i < PRESETS.length; i++) {
        var p = PRESETS[i];
        if (Math.round(Number(blur)) === p.blur
                && close(opacity, p.opacity, 0.015)
                && close(liquid, p.liquid, 0.06)
                && close(rim, p.rim, 0.03)
                && close(grain, p.grain, 0.008))
            return i;
    }
    return -1;
}

function nearestIndex(blur, opacity, liquid) {
    var best = 0, score = 1e9;
    for (var i = 0; i < PRESETS.length; i++) {
        var p = PRESETS[i];
        var d = Math.abs(Number(blur) - p.blur) / 8
            + Math.abs(Number(opacity) - p.opacity) / 0.7
            + Math.abs(Number(liquid) - p.liquid) / 1.5;
        if (d < score) {
            score = d;
            best = i;
        }
    }
    return best;
}

function matchId(blur, opacity, liquid, rim, grain) {
    var index = matchIndex(blur, opacity, liquid, rim, grain);
    return index < 0 ? "custom" : PRESETS[index].id;
}

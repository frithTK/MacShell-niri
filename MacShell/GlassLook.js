.pragma library

// Named glass looks for Appearance, ordered from most to least transparent
// (Vibrant trades a little frosting for a stronger lens). Transparent looks
// keep blur below 8 so the shader samples a full-resolution backdrop;
// Frosted blurs harder because it should hide what is behind it.
var PRESETS = [
    {id: "clear", blur: 3, opacity: 0.16, liquid: 1.15, rim: 0.5, grain: 0.01},
    {id: "standard", blur: 4, opacity: 0.28, liquid: 1.2, rim: 0.55, grain: 0.02},
    {id: "vibrant", blur: 5, opacity: 0.22, liquid: 1.4, rim: 0.65, grain: 0.02},
    {id: "tinted", blur: 6, opacity: 0.52, liquid: 1.1, rim: 0.5, grain: 0.02},
    {id: "frosted", blur: 12, opacity: 0.72, liquid: 1.0, rim: 0.45, grain: 0.04}
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

function indexOf(id) {
    for (var i = 0; i < PRESETS.length; i++) {
        if (PRESETS[i].id === id)
            return i;
    }
    return -1;
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

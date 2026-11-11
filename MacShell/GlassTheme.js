.pragma library

function clampFrosting(frosting) {
    return Math.max(0, Math.min(1, Number(frosting)));
}

function lightTint(frosting) { return .64 + clampFrosting(frosting) * .28; }

// Shader film over a refracted backdrop. Dark mode stays a clear lens (white
// ink). Light mode needs a white body so dark ink does not sit on wallpaper.
// Above 0.3 the film thickens quickly so Tinted and Frosted read as less
// transparent materials instead of a slightly darker lens.
function shaderTint(dark, frosting) {
    var f = clampFrosting(frosting);
    var thick = Math.max(0, f - .3);
    return Math.min(1, dark ? (.08 + f * .28 + thick * 1.4) : (.32 + f * .22 + thick * 1.2));
}

function cardShaderTint(dark, frosting) {
    var f = clampFrosting(frosting);
    return dark ? (.12 + f * .32) : (.46 + f * .28);
}

// Widget cards and Control Center tiles: named looks must actually change
// frosting. The Liquid Glass shader's 0.55 * opacity curve is too compressed
// on small slabs (Clear 0.09 vs Frosted 0.34), so these match the desktop widgets.
function darkTint(frosting) { return Math.min(.92, .25 + clampFrosting(frosting) * .8); }
function cardTint(frosting) { return Math.min(.92, .45 + clampFrosting(frosting) * .9); }
function materialTint(dark, frosting) { return dark ? darkTint(frosting) : cardTint(frosting); }

// Overlay alpha painted on compositor glass. `material` is Control Center /
// widget cards: named looks must jump, not sit in the 0.25–0.55 band.
function compositorAlpha(dark, frosting, material) {
    if (material)
        return materialTint(dark, frosting);
    return dark ? (.15 + clampFrosting(frosting) * .65) : lightTint(frosting);
}

// Sampled sRGB mean (0..1) behind a popup. 1 = force light glass, -1 = force
// dark, 0 = keep the theme. Light material is judged after its white frosting:
// a dark wallpaper must not flip Light appearance to dark popovers.
function popupTone(dark, sample, frosting) {
    var v = Math.max(0, Math.min(1, Number(sample)));
    if (dark) {
        var tint = Math.min(.45, compositorAlpha(true, frosting, false));
        var L = Math.pow(v, 2.2);
        var effD = L * (1 - tint) + .004 * tint;
        return (1.05 / (effD + .05)) < 3 ? 1 : 0;
    }
    var light = compositorAlpha(false, frosting, false);
    var surface = Math.pow(v * (1 - light) + light, 2.2);
    return ((surface + .05) / .062) < 3 ? -1 : 0;
}

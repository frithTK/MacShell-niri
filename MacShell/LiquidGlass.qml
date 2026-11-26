import QtQuick
import QtQuick.Effects
import "GlassTheme.js" as GlassTheme

Item {
    id: g
    required property var host
    property Item backdrop: null
    property url shaderUrl: ""
    property bool liquid: false
    property bool dark: true
    property real cornerR: 20
    property real tint: 0.4             // 0..1, from the translucency setting
    property real thickness: 30
    property real strength: 1.0         // liquid glass strength multiplier
    property real rim: 0.45
    property real grain: 0.03
    property real blur: 5               // backdrop blur radius, px (settings slider)
    property bool debug: false
    property bool material: false
    property bool fxArmed: false
    // Reload pauses the declarative `active` binding instead of assigning
    // it: an assignment made while the slab is hidden would stay false.
    property bool fxPaused: false
    signal shaderError()
    function reloadFx() {
        if (!fxArmed || !fxLoader.active) return;
        fxPaused = true;
        Qt.callLater(function () { g.fxPaused = false; });
    }

    MappedRect {
        id: slabMapping
        sourceItem: g; targetItem: g.backdrop
        padding: 82 // shader shadow (10) + sampling margin (72)
    }
        // The live capture stays off until this open is mostly faded in. The slab
        // already exists, so this is not a delay from shell startup: a panel that
        // is already open, a theme change and the glass slider still refresh at once.
        // Closing drops back to the flat fill with the fade instead of sampling to the last pixel.
        readonly property bool revealed: slabMapping.effectiveOpacity >= 0.85
        readonly property bool refracting: host !== null && liquid && host.captureGlass(g) && revealed
    GlassFallback {
        visible: !g.refracting
        anchors.fill: parent; radius: g.cornerR
        dark: g.dark; material: g.material; frosting: g.tint
        intensity: g.liquid ? g.strength : 0
        blurAmount: g.blur
        blurEnabled: host === null || !host.gaming
    }
    Timer { interval: 1; running: true; onTriggered: g.fxArmed = true }
    Connections { target: host; function onGlassLookSigChanged() { g.reloadFx(); } }
    Loader {
        id: fxLoader
        anchors.fill: parent
        active: !g.fxPaused && g.refracting && g.backdrop !== null && slabMapping.effectiveOpacity > 0.01
        sourceComponent: Item {
            id: lg
            readonly property real m: 72     // extra backdrop captured around the slab (refraction + blur reach)
            readonly property real p: 10     // shader padding (drop shadow)
            // a Gaussian blur of 8 px or more doesn't need full resolution: blurring at half size is visually identical
            // and costs a quarter of the GPU work, every frame
            readonly property real ds: g.blur >= 8 ? 0.5 : 1.0
            readonly property real bn: g.blur * 1.4 * ds / 64.0     // blur amount in MultiEffect units (at the reduced size)
            ShaderEffectSource {
                id: bsrc
                sourceItem: g.backdrop
                hideSource: true
                live: true
                visible: false
                sourceRect: slabMapping.rect
                textureSize: Qt.size(Math.max(1, Math.round(sourceRect.width * lg.ds)), Math.max(1, Math.round(sourceRect.height * lg.ds)))
            }
            MultiEffect {
                id: bblurFx
                source: bsrc
                width: bsrc.sourceRect.width * lg.ds; height: bsrc.sourceRect.height * lg.ds
                blurEnabled: g.blur > 0
                blurMax: 64
                blur: Math.min(1.0, lg.bn)
                autoPaddingEnabled: false
                visible: false
            }
            // real Gaussian pre-blur of the backdrop (Qt MultiEffect): the glass shader refracts THIS texture,
            // so there are no sampled copies of the background any more
            ShaderEffectSource {
                id: bblur
                sourceItem: bblurFx
                live: true
                visible: false
            }
            MultiEffect {
                id: bblur2Fx
                source: bblur
                width: bsrc.sourceRect.width * lg.ds; height: bsrc.sourceRect.height * lg.ds
                blurEnabled: lg.bn > 1.0
                blurMax: 64
                blur: Math.max(0.0, Math.min(1.0, lg.bn - 1.0))
                autoPaddingEnabled: false
                visible: false
            }
            // second Gaussian pass: only active when the slider goes past a single pass's 64 px limit
            ShaderEffectSource {
                id: bblur2
                // the 2nd pass is a pure copy unless the blur radius exceeds one pass: skip it then (same pixels, one GPU pass less)
                sourceItem: lg.bn > 1.0 ? bblur2Fx : null
                live: true
                visible: false
            }
            ShaderEffect {
                id: fx
                x: -lg.p; y: -lg.p
                width: g.width + 2 * lg.p
                height: g.height + 2 * lg.p
                fragmentShader: g.shaderUrl
                onStatusChanged: {
                    console.log("[macbar-glass] shader status:", status, "(0 = compiled, 1 = uncompiled, 2 = error)", log);
                    if (status === ShaderEffect.Error) g.shaderError();
                }
                property variant src: lg.bn > 1.0 ? bblur2 : bblur
                property real padPx: lg.p
                property vector2d itemSize: Qt.vector2d(width, height)
                property vector2d glassSize: Qt.vector2d(g.width, g.height)
                // sourceRect is already the on-screen rectangle, popover scale included
                // (MappedRect). These stay in the slab's own pixels, which that rectangle maps onto.
                property vector2d srcSize: Qt.vector2d(g.width + 2 * (lg.p + lg.m), g.height + 2 * (lg.p + lg.m))
                property vector2d srcOffset: Qt.vector2d(lg.m, lg.m)
                property real pad: lg.p
                property real radius: g.cornerR
                property real bezel: Math.min(g.height * 0.36, 26)
                property real thickness: g.thickness * g.strength * 1.6      // bar popovers: boosted to match the stronger dock glass
                property real dispersion: 0.06 * g.strength * 1.3
                property real magnify: 0.05 * g.strength * 1.6
                property real rim: g.rim
                property real grain: g.grain * 0.2
                property real blurPx: g.blur > 0 ? 1.5 : 0
                property real tintMix: g.material
                    ? GlassTheme.cardShaderTint(g.dark, g.tint)
                    : GlassTheme.shaderTint(g.dark, g.tint)
                property real saturation: 1.25
                property real dark: g.dark ? 1 : 0
                property real debug: g.debug ? 1 : 0
                property real shadowAmt: 1
                property real rimTint: 0
                property real ringW: 0
                property real flatInner: 0
            }
        }
    }
}


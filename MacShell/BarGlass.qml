import QtQuick
import "GlassTheme.js" as GlassTheme

Item {
    id: gg
    required property var host
    required property var gx
    property real cornerR: 22
    property real thickness: 24
    property real strengthMul: 1.0
    property real tintMul: 1.0
    property real shadowAmt: 0.5
    property real flatInner: 0
    property bool fxArmed: false
    property bool fxPaused: false
    readonly property real pad: 10
    function reloadFx() {
        if (!fxArmed || !fxLoader.active) return;
        fxPaused = true;
        Qt.callLater(function () { gg.fxPaused = false; });
    }
    // Look values bind to MacBar properties, not gx.*: GlassCtx is a `var`, so
    // nested gx.tint / gx.blur bindings do not update when a preset is applied.
    readonly property bool materialLook: gx.tintMix >= 0
    readonly property bool lookDark: host.effDark
    readonly property bool lookLiquid: host.liquidActive
    readonly property bool lookDebug: host.glassDebug
    readonly property real lookTint: host.glassOpacity
    readonly property real lookTintMix: materialLook
        ? GlassTheme.cardShaderTint(host.effDark, host.glassOpacity)
        : GlassTheme.shaderTint(host.effDark, host.glassOpacity)
    readonly property real lookStrength: host.glassLiquid
    readonly property real lookBlur: host.glassBlur + (materialLook ? 4 : 0)
    readonly property real lookBlurMul: gx.blurMul
    readonly property real lookLiquidMul: gx.liquidMul
    readonly property real lookRim: host.glassRim
    readonly property real lookGrain: host.glassGrain
    readonly property real lookPane: gx.paneOpacity

    MappedRect { id: slabMapping; sourceItem: gg; targetItem: gg.gx.frame }

    // Same gate as the Dock: shader only when niri gave real window
    // positions. Otherwise GlassFallback lets the compositor blur live
    // windows under the slab instead of painting a wallpaper reconstruction.
    readonly property bool refracting: lookLiquid && host.captureGlass(gg) && gg.gx && gg.gx.src !== null
    GlassFallback {
        visible: !gg.refracting
        anchors.fill: parent; radius: gg.cornerR
        dark: gg.lookDark
        material: gg.materialLook
        frosting: gg.lookTint * (gg.materialLook ? 1 : gg.tintMul)
        intensity: gg.lookLiquid ? gg.lookStrength : 0
        blurAmount: gg.lookBlur
        blurEnabled: !host.gaming
    }
    Timer { interval: 1; running: true; onTriggered: gg.fxArmed = true }
    Connections { target: host; function onGlassLookSigChanged() { gg.reloadFx(); } }
    Loader {
        id: fxLoader
        anchors.fill: parent
        active: !gg.fxPaused && gg.refracting && gg.gx.src !== null && slabMapping.effectiveOpacity > 0.01
        sourceComponent: Item {
            ShaderEffect {
                x: -gg.pad; y: -gg.pad
                width: gg.width + 2 * gg.pad
                height: gg.height + 2 * gg.pad
                fragmentShader: gg.gx.shaderUrl
                onStatusChanged: if (status === ShaderEffect.Error) gg.gx.failed()
                opacity: gg.lookPane
                property variant src: gg.gx.src
                property vector2d itemSize: Qt.vector2d(width, height)
                property vector2d glassSize: Qt.vector2d(gg.width, gg.height)
                property vector2d srcSize: Qt.vector2d(gg.gx.srcRect.width / Math.max(.001, slabMapping.scaleX),
                                                     gg.gx.srcRect.height / Math.max(.001, slabMapping.scaleY))
                property vector2d srcOffset: Qt.vector2d((slabMapping.rect.x - gg.gx.srcRect.x) / Math.max(.001, slabMapping.scaleX) - gg.pad,
                                                       (slabMapping.rect.y - gg.gx.srcRect.y) / Math.max(.001, slabMapping.scaleY) - gg.pad)
                property real pad: gg.pad
                property real radius: gg.cornerR
                property real bezel: Math.min(gg.height * 0.36, 26)
                property real thickness: gg.thickness * gg.lookStrength * gg.strengthMul * gg.lookLiquidMul * 1.6
                property real dispersion: 0.06 * gg.lookStrength * gg.strengthMul * gg.lookLiquidMul * 1.3
                property real magnify: 0.05 * gg.lookStrength * gg.strengthMul * gg.lookLiquidMul * 1.6
                property real rim: gg.lookRim
                property real grain: gg.lookGrain * 0.2
                property real blurPx: gg.lookBlur * gg.lookBlurMul > 0 ? 1.5 : 0
                property real tintMix: gg.lookTintMix * gg.tintMul
                property real saturation: 1.25
                property real dark: gg.lookDark ? 1 : 0
                property real debug: gg.lookDebug ? 1 : 0
                property real shadowAmt: gg.shadowAmt
                property real rimTint: 0
                property real ringW: 0
                property real flatInner: gg.flatInner
            }
        }
    }
}

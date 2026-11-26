import QtQuick

QtObject {
    property var src: null                          // the ShaderEffectSource holding the backdrop
    property rect srcRect: Qt.rect(0, 0, 1, 1)      // where that texture sits, in `frame` coordinates
    property Item frame: null                       // coordinate space of srcRect (the popover layer)
    property bool liquid: false
    property url shaderUrl: ""
    property bool dark: true
    property real tint: 0.4
    property real strength: 1.0
    property real blur: 5               // base backdrop blur radius, px (settings slider)
    property real blurMul: 1.0          // scales the backdrop blur radius of every slab in this context
    property real liquidMul: 1.0        // scales refraction / dispersion / magnify of every slab in this context
    property real paneOpacity: 1.0      // <1 lets the compositor blur show through the shader pane
    property real rim: 0.45
    property real grain: 0.03
    property bool debug: false
    // Final shader frosting. <0 means derive from tint (bar popovers / Spotlight).
    property real tintMix: -1
    signal failed()
}

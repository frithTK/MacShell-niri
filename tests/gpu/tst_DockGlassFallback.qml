import QtQuick
import QtTest

// Models MacDock's per-screen ShaderEffect Variants: one shared dockGlassFailed
// flag and one shared fallback QSB. qmltestrunner may leave a valid QSB
// Uncompiled; Error on a missing file is enough to exercise the fallback.
TestCase {
    id: test
    name: "DockGlassFallback"
    when: windowShown
    visible: true
    width: 420
    height: 160

    property bool dockGlassFailed: false
    property string glassState: "ready"
    property url dockGlassUrl: Qt.resolvedUrl("../../MacShell/dockglass.frag.qsb")
    property url glassShaderUrl: Qt.resolvedUrl("../../MacShell/liquidglass.frag.qsb")
    property url missingDockQsb: "file:///nonexistent/macshell-dockglass.frag.qsb"
    property url missingFallbackQsb: "file:///nonexistent/macshell-liquidglass.frag.qsb"
    property real dark: 1

    function handleStatus(fx) {
        if (fx.status !== ShaderEffect.Error)
            return;
        const failedShader = String(fx.fragmentShader);
        Qt.callLater(() => {
            if (fx.status !== ShaderEffect.Error || String(fx.fragmentShader) !== failedShader)
                return;
            if (failedShader === String(glassShaderUrl))
                glassState = "failed";
            else
                dockGlassFailed = true;
        });
    }

    Rectangle {
        id: picture
        width: 220
        height: 80
        color: test.dark ? "#1c1c1e" : "#e8e8ed"
        visible: false
    }
    ShaderEffectSource {
        id: texture
        sourceItem: picture
        hideSource: false
        live: true
        mipmap: true
        visible: false
    }

    ShaderEffect {
        id: pane0
        objectName: "dockGlassEffect0"
        x: 16; y: 16; width: 180; height: 56
        fragmentShader: test.dockGlassFailed ? test.glassShaderUrl : test.dockGlassUrl
        onStatusChanged: test.handleStatus(this)
        property variant src: texture
        property vector2d itemSize: Qt.vector2d(width, height)
        property vector2d glassSize: Qt.vector2d(160, 48)
        property vector2d srcSize: Qt.vector2d(picture.width, picture.height)
        property vector2d srcOffset: Qt.vector2d(10, 4)
        property real pad: 10
        property real radius: 16
        property real bezel: 20
        property real thickness: 24
        property real dispersion: 0.06
        property real magnify: 0.08
        property real rim: 0.9
        property real grain: 0.02
        property real blurPx: 1.5
        property real tintMix: test.dark ? 0.13 : 0.08
        property real saturation: 1.25
        property real dark: test.dark
        property real debug: 0
        property real shadowAmt: 1
        property real rimTint: 0
        property real ringW: 0
        property real flatInner: 0
        property vector4d edgeTint: Qt.vector4d(0, 0, 0, 0)
    }
    ShaderEffect {
        id: pane1
        objectName: "dockGlassEffect1"
        x: 220; y: 16; width: 180; height: 56
        fragmentShader: test.dockGlassFailed ? test.glassShaderUrl : test.dockGlassUrl
        onStatusChanged: test.handleStatus(this)
        property variant src: texture
        property vector2d itemSize: Qt.vector2d(width, height)
        property vector2d glassSize: Qt.vector2d(160, 48)
        property vector2d srcSize: Qt.vector2d(picture.width, picture.height)
        property vector2d srcOffset: Qt.vector2d(10, 4)
        property real pad: 10
        property real radius: 16
        property real bezel: 20
        property real thickness: 24
        property real dispersion: 0.06
        property real magnify: 0.08
        property real rim: 0.9
        property real grain: 0.02
        property real blurPx: 1.5
        property real tintMix: test.dark ? 0.13 : 0.08
        property real saturation: 1.25
        property real dark: test.dark
        property real debug: 0
        property real shadowAmt: 1
        property real rimTint: 0
        property real ringW: 0
        property real flatInner: 0
        property vector4d edgeTint: Qt.vector4d(0, 0, 0, 0)
    }

    function test_fallback_pipeline() {
        wait(200)
        verify(!dockGlassFailed)
        compare(glassState, "ready")
        verify(pane0.status !== ShaderEffect.Error)
        verify(pane1.status !== ShaderEffect.Error)
        compare(String(pane0.fragmentShader), String(pane1.fragmentShader))

        dark = 1
        dockGlassUrl = missingDockQsb
        tryVerify(function() { return dockGlassFailed && glassState === "ready" }, 3000)
        compare(String(pane0.fragmentShader), String(glassShaderUrl))
        compare(String(pane1.fragmentShader), String(glassShaderUrl))
        verify(String(pane0.fragmentShader).indexOf("liquidglass") >= 0)

        dark = 0
        wait(50)
        verify(dockGlassFailed)
        compare(glassState, "ready")
        compare(String(pane0.fragmentShader), String(pane1.fragmentShader))
        verify(String(pane0.fragmentShader).indexOf("liquidglass") >= 0)

        glassShaderUrl = missingFallbackQsb
        tryVerify(function() { return glassState === "failed" }, 3000)
        verify(dockGlassFailed)
        compare(pane0.status, ShaderEffect.Error)
        compare(pane1.status, ShaderEffect.Error)
    }
}

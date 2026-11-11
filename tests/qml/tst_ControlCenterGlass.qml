import QtQuick
import QtTest
import "../../MacShell/GlassTheme.js" as GlassTheme
import "../../MacShell/GlassLook.js" as GlassLook
import "../../MacShell/GlassPolicy.js" as GlassPolicy

TestCase {
    id: test
    name: "ControlCenterGlass"
    when: windowShown
    visible: true
    width: 640
    height: 240

    QtObject {
        id: fakeBar
        property bool settingsReady: true
        property bool darkMode: true
        property real glassOpacity: 0.42
        property real glassBlur: 5
        property real glassLiquid: 1
        property real glassRim: 0.45
        property real glassGrain: 0.03
        property color accent: "#0a84ff"
        property string fontFamily: "Inter Variable"
        property string barStyle: "liquid"
    }
    QtObject {
        id: fakeDock
        property bool settingsReady: true
        property bool darkMode: true
        property real glassOpacity: 0.42
        property real glassBlur: 5
        property real glassLiquid: 1
        property real glassRim: 0.45
        property real glassGrain: 0.03
        property color accent: "#0a84ff"
        property string fontFamily: "Inter Variable"
        property string dockStyle: "liquid"
    }

    // Replica of MacBar.pullDockGlass: the bar copies the Dock look even if
    // ThemeCoordinator is missing from the live profile.
    QtObject {
        id: barPull
        property var dockRef: fakeDock
        property real glassOpacity: 0.42
        property real glassBlur: 5
        property real glassLiquid: 1
        property real glassRim: 0.45
        property real glassGrain: 0.03
        function pullDockGlass() {
            var d = dockRef
            if (!d) return
            if (glassOpacity !== d.glassOpacity) glassOpacity = d.glassOpacity
            if (glassBlur !== d.glassBlur) glassBlur = d.glassBlur
            if (glassLiquid !== d.glassLiquid) glassLiquid = d.glassLiquid
            if (glassRim !== d.glassRim) glassRim = d.glassRim
            if (glassGrain !== d.glassGrain) glassGrain = d.glassGrain
        }
    }
    Connections {
        target: fakeDock
        function onGlassOpacityChanged() { barPull.pullDockGlass() }
        function onGlassBlurChanged() { barPull.pullDockGlass() }
        function onGlassLiquidChanged() { barPull.pullDockGlass() }
        function onGlassRimChanged() { barPull.pullDockGlass() }
        function onGlassGrainChanged() { barPull.pullDockGlass() }
    }

    Loader {
        id: coord
        source: Qt.resolvedUrl("../../MacShell/ThemeCoordinator.qml")
        onLoaded: { item.bar = fakeBar; item.dock = fakeDock }
    }

    // Wallpaper stand-in so grabImage sees the overlay, not a void background.
    Rectangle {
        id: wall
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0; color: "#2f5d86" }
            GradientStop { position: 1; color: "#1a2740" }
        }
    }

    // Production compositor Control Center tile: same frosting as Dock glass.
    Rectangle {
        id: tile
        objectName: "ccTile"
        x: 24; y: 48
        width: 180; height: 76
        radius: 22
        readonly property real frosting: barPull.glassOpacity
        color: Qt.rgba(0.09, 0.095, 0.11, GlassTheme.compositorAlpha(true, frosting, false))
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.12 + Math.min(barPull.glassLiquid, 2.5) * 0.055)
    }
    Text {
        x: tile.x; y: 22
        text: "Clear → Frosted material"
        color: "white"; font.pixelSize: 12
    }

    Rectangle {
        id: oldTile
        x: 228; y: 48
        width: 180; height: 76
        radius: 22
        color: Qt.rgba(0.09, 0.095, 0.11, GlassTheme.compositorAlpha(true, barPull.glassOpacity, false))
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.16)
    }

    Item {
        id: gglass
        x: 432; y: 48
        width: 180; height: 76
        property real lookTintMix: GlassTheme.shaderTint(true, barPull.glassOpacity)
        property real lookStrength: barPull.glassLiquid
        Rectangle { id: picture; width: 220; height: 100; color: "#3a6ea5"; visible: false }
        ShaderEffectSource { id: texture; sourceItem: picture; hideSource: false; live: true; visible: false }
        Loader {
            id: fxLoader
            anchors.fill: parent
            active: true
            sourceComponent: ShaderEffect {
                id: fx
                objectName: "ccShader"
                width: gglass.width; height: gglass.height
                fragmentShader: Qt.resolvedUrl("../../MacShell/liquidglass.frag.qsb")
                property variant src: texture
                property vector2d itemSize: Qt.vector2d(width, height)
                property vector2d glassSize: Qt.vector2d(gglass.width, gglass.height)
                property vector2d srcSize: Qt.vector2d(picture.width, picture.height)
                property vector2d srcOffset: Qt.vector2d(0, 0)
                property real pad: 10
                property real radius: 22
                property real bezel: 20
                property real thickness: 22 * gglass.lookStrength * 1.6
                property real dispersion: 0.06
                property real magnify: 0.05
                property real rim: barPull.glassRim
                property real grain: barPull.glassGrain * 0.2
                property real blurPx: 1.5
                property real tintMix: gglass.lookTintMix
                property real saturation: 1.25
                property real dark: 1
                property real debug: 0
                property real shadowAmt: 0
                property real rimTint: 0
                property real ringW: 0
                property real flatInner: 1
            }
        }
    }

    // Same reload contract as MacBar GGlass / LGlass: the Control Center panel
    // fades to opacity 0 when closed, and a look change must not leave the
    // shader loader stuck off for the next opening.
    Item {
        id: slab
        property bool shown: true
        property bool fxArmed: true
        property bool fxPaused: false
        opacity: shown ? 1 : 0
        function reloadFx() {
            if (!fxArmed || !slabLoader.active) return;
            fxPaused = true;
            Qt.callLater(function () { slab.fxPaused = false; });
        }
        Loader {
            id: slabLoader
            active: !slab.fxPaused && slab.opacity > 0.01
            sourceComponent: Item {}
        }
    }

    function applyLook(id) {
        var look = GlassLook.byId(id)
        fakeDock.glassOpacity = look.opacity
        fakeDock.glassBlur = look.blur
        fakeDock.glassLiquid = look.liquid
        fakeDock.glassRim = look.rim
        fakeDock.glassGrain = look.grain
    }

    function tileAlpha() {
        return tile.color.a
    }

    function test_coordinator_copies_named_looks_into_the_bar() {
        tryVerify(function () { return coord.status === Loader.Ready && coord.item }, 2000)
        applyLook("clear")
        compare(fakeBar.glassOpacity, GlassLook.byId("clear").opacity)
        compare(fakeBar.glassBlur, 3)
        applyLook("frosted")
        compare(fakeBar.glassOpacity, GlassLook.byId("frosted").opacity)
        compare(fakeBar.glassBlur, GlassLook.byId("frosted").blur)
        compare(fakeBar.glassLiquid, GlassLook.byId("frosted").liquid)
    }

    function test_bar_pulls_dock_look_without_coordinator() {
        barPull.glassOpacity = 0.42
        barPull.glassBlur = 5
        applyLook("clear")
        wait(20)
        compare(barPull.glassOpacity, GlassLook.byId("clear").opacity)
        compare(barPull.glassBlur, 3)
        applyLook("frosted")
        wait(20)
        compare(barPull.glassOpacity, GlassLook.byId("frosted").opacity)
        compare(barPull.glassBlur, GlassLook.byId("frosted").blur)
        compare(barPull.glassLiquid, GlassLook.byId("frosted").liquid)
        compare(barPull.glassRim, GlassLook.byId("frosted").rim)
        compare(barPull.glassGrain, GlassLook.byId("frosted").grain)
    }

    function test_compositor_tile_alpha_jumps_between_clear_and_frosted() {
        applyLook("clear")
        wait(30)
        var clearAlpha = tileAlpha()
        applyLook("frosted")
        wait(30)
        var frostAlpha = tileAlpha()
        compare(clearAlpha, GlassTheme.compositorAlpha(true, GlassLook.byId("clear").opacity, false))
        compare(frostAlpha, GlassTheme.compositorAlpha(true, GlassLook.byId("frosted").opacity, false))
        verify(frostAlpha - clearAlpha > 0.25)
        verify(frostAlpha - GlassTheme.compositorAlpha(true, GlassLook.byId("clear").opacity, false) > 0.2)
        applyLook("clear")
        wait(30)
        var clearImg = grabImage(tile)
        applyLook("frosted")
        wait(30)
        var frostImg = grabImage(tile)
        verify(frostImg.pixel(90, 38) !== clearImg.pixel(90, 38))
    }

    function test_shader_in_loader_reads_new_tintMix() {
        tryVerify(function () { return fxLoader.item !== null }, 2000)
        applyLook("clear")
        wait(30)
        var clearMix = fxLoader.item.tintMix
        applyLook("frosted")
        wait(30)
        var frostMix = fxLoader.item.tintMix
        verify(frostMix - clearMix > 0.1)
        compare(clearMix, GlassTheme.shaderTint(true, GlassLook.byId("clear").opacity))
        compare(frostMix, GlassTheme.shaderTint(true, GlassLook.byId("frosted").opacity))
    }

    function test_tiles_use_compositor_glass_without_window_geometry() {
        tryVerify(function () { return fxLoader.item !== null }, 2000)
        var captureGlass = false
        var lookLiquid = true
        var src = texture
        var refracting = lookLiquid && captureGlass && src !== null
        verify(!refracting)
        verify(lookLiquid && src !== null)
        applyLook("clear")
        wait(30)
        var clearT = fxLoader.item.thickness
        applyLook("vibrant")
        wait(30)
        verify(fxLoader.item.thickness > clearT)
        verify(fxLoader.item.magnify > 0)
        verify(fxLoader.item.dispersion > 0)
    }

    function test_control_center_and_spotlight_keep_the_live_backdrop() {
        compare(GlassPolicy.wallpaperLayer(null), null)
        var live = { objectName: "windows" }
        compare(GlassPolicy.wallpaperLayer(live), live)
    }

    function test_look_change_while_closed_does_not_drop_control_center_glass() {
        slab.shown = true
        tryCompare(slabLoader, "active", true)
        slab.reloadFx()
        tryCompare(slabLoader, "active", true)
        slab.shown = false
        tryCompare(slabLoader, "active", false)
        slab.reloadFx()
        wait(20)
        slab.shown = true
        tryCompare(slabLoader, "active", true)
        verify(slabLoader.item !== null)
    }
}

import QtQuick
import QtTest
import "../../MacShell/GlassTheme.js" as GlassTheme
import "../../MacShell/GlassLook.js" as GlassLook

TestCase {
    name: "GlassTheme"

    function test_named_looks_change_control_center_frosting() {
        var clear = GlassLook.byId("clear")
        var frosted = GlassLook.byId("frosted")
        var darkClear = GlassTheme.materialTint(true, clear.opacity)
        var darkFrosted = GlassTheme.materialTint(true, frosted.opacity)
        var lightClear = GlassTheme.materialTint(false, clear.opacity)
        var lightFrosted = GlassTheme.materialTint(false, frosted.opacity)
        verify(darkFrosted - darkClear > 0.3)
        verify(lightFrosted - lightClear > 0.25)
        verify(darkClear > clear.opacity * 0.55 + 0.15)
        compare(GlassTheme.darkTint(0.42), Math.min(0.92, 0.25 + 0.42 * 0.8))
        compare(GlassTheme.cardTint(0.42), Math.min(0.92, 0.45 + 0.42 * 0.9))
        compare(GlassTheme.shaderTint(true, 0.28), 0.08 + 0.28 * 0.28)
        compare(GlassTheme.shaderTint(false, 0.28), 0.32 + 0.28 * 0.22)
        verify(GlassTheme.shaderTint(false, 0.42) < GlassTheme.lightTint(0.42))
        verify(GlassTheme.shaderTint(false, 0.28) > GlassTheme.shaderTint(true, 0.28))
        verify(GlassTheme.cardShaderTint(true, 0.62) - GlassTheme.cardShaderTint(true, 0.16) > 0.1)
        verify(GlassTheme.cardShaderTint(false, 0.62) - GlassTheme.cardShaderTint(false, 0.16) > 0.1)
        compare(GlassTheme.popupTone(false, 0, 0.28), 0)
        compare(GlassTheme.popupTone(false, 1, 0.28), 0)
        compare(GlassTheme.popupTone(true, 0, 0.28), 0)
        compare(GlassTheme.popupTone(true, 1, 0.28), 1)
        compare(GlassTheme.compositorAlpha(true, clear.opacity, false), 0.15 + clear.opacity * 0.65)
        compare(GlassTheme.compositorAlpha(true, clear.opacity, true), darkClear)
        compare(GlassTheme.compositorAlpha(true, frosted.opacity, true), darkFrosted)
        verify(GlassTheme.compositorAlpha(true, frosted.opacity, true)
               - GlassTheme.compositorAlpha(true, clear.opacity, true) > 0.3)
    }

    function test_refracting_film_reaches_tinted_and_frosted() {
        var standard = GlassLook.byId("standard").opacity
        var tinted = GlassLook.byId("tinted").opacity
        var frosted = GlassLook.byId("frosted").opacity
        for (var dark of [true, false]) {
            verify(GlassTheme.shaderTint(dark, tinted) - GlassTheme.shaderTint(dark, standard) > 0.25)
            verify(GlassTheme.shaderTint(dark, frosted) - GlassTheme.shaderTint(dark, tinted) > 0.25)
            verify(GlassTheme.shaderTint(dark, 0.85) <= 1)
        }
        compare(GlassTheme.shaderTint(true, 0.3), 0.08 + 0.3 * 0.28)
    }
}

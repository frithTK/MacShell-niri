import QtQuick
import QtTest
import "../../MacShell/GlassLook.js" as GlassLook

TestCase {
    name: "GlassLook"

    function test_named_looks_are_valid_and_round_trip() {
        compare(GlassLook.count(), 5)
        compare(GlassLook.ids(), ["clear", "standard", "vibrant", "tinted", "frosted"])
        for (var i = 0; i < GlassLook.count(); i++) {
            var look = GlassLook.at(i)
            verify(look.blur >= 0 && look.blur <= 80)
            verify(look.opacity > 0 && look.opacity < 0.85)
            verify(look.liquid >= 0 && look.liquid <= 2.5)
            compare(GlassLook.byId(look.id).id, look.id)
            compare(GlassLook.matchIndex(look.blur, look.opacity, look.liquid, look.rim, look.grain), i)
        }
        compare(GlassLook.byId("missing"), null)
        compare(GlassLook.indexOf("clear"), 0)
        compare(GlassLook.indexOf("tinted"), 3)
        compare(GlassLook.indexOf("frosted"), 4)
        compare(GlassLook.indexOf("missing"), -1)
        compare(GlassLook.at(-1).id, "clear")
        compare(GlassLook.at(99).id, "frosted")
    }

    function test_transparent_looks_stay_full_resolution() {
        for (var id of ["clear", "standard", "vibrant", "tinted"])
            verify(GlassLook.byId(id).blur < 8)
        verify(GlassLook.byId("frosted").blur > GlassLook.byId("tinted").blur)
    }

    function test_tinted_and_frosted_are_less_transparent() {
        var standard = GlassLook.byId("standard").opacity
        var tinted = GlassLook.byId("tinted").opacity
        var frosted = GlassLook.byId("frosted").opacity
        verify(tinted - standard > 0.15)
        verify(frosted - tinted > 0.15)
    }

    function test_factory_defaults_are_standard() {
        var look = GlassLook.byId("standard")
        compare(look.blur, 4)
        compare(look.opacity, 0.28)
        compare(look.liquid, 1.2)
        compare(GlassLook.matchId(4, 0.28, 1.2, 0.55, 0.02), "standard")
    }

    function test_named_looks_keep_refraction() {
        for (var i = 0; i < GlassLook.count(); i++)
            verify(GlassLook.at(i).liquid >= 1.0)
    }

    function test_unknown_values_are_custom_and_nearest_snaps() {
        compare(GlassLook.matchIndex(7, 0.14, 0.65, 0.45, 0.03), -1)
        compare(GlassLook.matchId(7, 0.14, 0.65, 0.45, 0.03), "custom")
        compare(GlassLook.nearestIndex(3, 0.16, 1.15), 0)
        compare(GlassLook.nearestIndex(4, 0.28, 1.2), 1)
        compare(GlassLook.nearestIndex(5, 0.22, 1.4), 2)
        compare(GlassLook.nearestIndex(6, 0.5, 1.1), 3)
        compare(GlassLook.nearestIndex(20, 0.7, 0.7), 4)
    }

    function test_partial_apply_does_not_match_and_nearest_stays_on_old_look() {
        var from = GlassLook.byId("vibrant")
        var to = GlassLook.byId("frosted")
        compare(GlassLook.matchIndex(from.blur, from.opacity, from.liquid, to.rim, from.grain), -1)
        compare(GlassLook.nearestIndex(from.blur, from.opacity, from.liquid), 2)
        compare(GlassLook.indexOf(to.id), 4)
    }

    function test_named_look_id_is_stable_when_values_are_mid_apply() {
        var from = GlassLook.byId("standard")
        var to = GlassLook.byId("frosted")
        compare(GlassLook.matchId(from.blur, from.opacity, from.liquid, to.rim, from.grain), "custom")
        compare(GlassLook.indexOf("frosted"), 4)
    }
}

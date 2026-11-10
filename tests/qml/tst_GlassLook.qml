import QtQuick
import QtTest
import "../../MacShell/GlassLook.js" as GlassLook

TestCase {
    name: "GlassLook"

    function test_named_looks_stay_full_resolution() {
        compare(GlassLook.count(), 4)
        compare(GlassLook.ids(), ["clear", "standard", "vibrant", "frosted"])
        for (var i = 0; i < GlassLook.count(); i++) {
            var look = GlassLook.at(i)
            verify(look.blur >= 0 && look.blur < 8)
            verify(look.opacity > 0 && look.opacity < 0.85)
            verify(look.liquid >= 0 && look.liquid <= 2.5)
            compare(GlassLook.byId(look.id).id, look.id)
            compare(GlassLook.matchIndex(look.blur, look.opacity, look.liquid, look.rim, look.grain), i)
        }
        compare(GlassLook.byId("missing"), null)
        compare(GlassLook.indexOf("clear"), 0)
        compare(GlassLook.indexOf("frosted"), 3)
        compare(GlassLook.indexOf("missing"), -1)
        compare(GlassLook.at(-1).id, "clear")
        compare(GlassLook.at(99).id, "frosted")
    }

    function test_factory_defaults_are_standard() {
        var look = GlassLook.byId("standard")
        compare(look.blur, 5)
        compare(look.opacity, 0.42)
        compare(look.liquid, 1.0)
        compare(GlassLook.matchId(5, 0.42, 1.0, 0.45, 0.03), "standard")
    }

    function test_unknown_values_are_custom_and_nearest_snaps() {
        compare(GlassLook.matchIndex(7, 0.14, 0.65, 0.45, 0.03), -1)
        compare(GlassLook.matchId(7, 0.14, 0.65, 0.45, 0.03), "custom")
        compare(GlassLook.nearestIndex(3, 0.16, 0.5), 0)
        compare(GlassLook.nearestIndex(5, 0.42, 1.0), 1)
        compare(GlassLook.nearestIndex(7, 0.24, 1.35), 2)
        compare(GlassLook.nearestIndex(7, 0.14, 0.65), 2)
        compare(GlassLook.nearestIndex(20, 0.7, 0.7), 3)
    }

    function test_partial_apply_does_not_match_and_nearest_stays_on_old_look() {
        var from = GlassLook.byId("vibrant")
        var to = GlassLook.byId("frosted")
        compare(GlassLook.matchIndex(from.blur, from.opacity, from.liquid, to.rim, from.grain), -1)
        compare(GlassLook.nearestIndex(from.blur, from.opacity, from.liquid), 2)
        compare(GlassLook.indexOf(to.id), 3)
    }

    function test_named_look_id_is_stable_when_values_are_mid_apply() {
        var from = GlassLook.byId("standard")
        var to = GlassLook.byId("frosted")
        compare(GlassLook.matchId(from.blur, from.opacity, from.liquid, to.rim, from.grain), "custom")
        compare(GlassLook.indexOf("frosted"), 3)
        compare(GlassLook.byId("frosted").blur < 8, true)
    }
}

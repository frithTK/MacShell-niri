import QtQuick
import QtTest
import "../../MacShell/GlassPolicy.js" as Policy

TestCase {
    name: "GlassPolicy"
    function test_unknown_tiled_geometry_uses_compositor() {
        var tiled = {id: 1, output: "A", workspaceActive: true, geometryKnown: false};
        compare(Policy.canRefract([tiled], "A", true, false, {"1": {}}), false);
        compare(Policy.canRefract([tiled], "B", true, false, {}), true);
        tiled.workspaceActive = false;
        compare(Policy.canRefract([tiled], "A", true, false, {}), true);
    }
    function test_known_geometry_waits_for_frame_and_capture() {
        var floating = {id: 2, output: "A", workspaceActive: true, geometryKnown: true};
        compare(Policy.canRefract([floating], "A", true, false, {}), false);
        compare(Policy.canRefract([floating], "A", true, false, {"2": {}}), true);
        compare(Policy.canRefract([floating], "A", false, false, {"2": {}}), false);
        compare(Policy.canRefract([floating], "A", true, true, {"2": {}}), false);
    }
    function test_offscreen_known_geometry_does_not_block_refraction() {
        var on = {id: 1, output: "A", workspaceActive: true, geometryKnown: true, hidden: false, at: [0, 0], size: [100, 100]};
        var off = {id: 2, output: "A", workspaceActive: true, geometryKnown: true, hidden: true, at: [2000, 0], size: [100, 100]};
        compare(Policy.canRefract([on, off], "A", true, false, {"1": {}}), true);
        compare(Policy.canRefract([on, off], "A", true, false, {"1": {}, "2": {}}), true);
    }
    function test_overlapping_windows_use_authoritative_compositor_order() {
        var a = {id: 1, output: "A", workspaceActive: true, geometryKnown: true, at: [0, 0], size: [100, 100]};
        var b = {id: 2, output: "A", workspaceActive: true, geometryKnown: true, at: [90, 0], size: [100, 100]};
        compare(Policy.canRefract([a, b], "A", true, false, {"1": {}, "2": {}}), false);
        b.at = [100, 0];
        compare(Policy.canRefract([a, b], "A", true, false, {"1": {}, "2": {}}), true);
    }
    function test_floating_window_over_tiles_keeps_refraction() {
        var tile = {id: 1, output: "A", workspaceActive: true, geometryKnown: true, floating: false, focusHistoryID: 1, at: [0, 0], size: [100, 100]};
        var settings = {id: 2, output: "A", workspaceActive: true, geometryKnown: true, floating: true, focusHistoryID: 1, at: [50, 0], size: [100, 100]};
        compare(Policy.canRefract([tile, settings], "A", true, false, {"1": {}, "2": {}}), true);
    }
    function test_overlapping_floating_windows_need_a_focused_one() {
        var a = {id: 1, output: "A", workspaceActive: true, geometryKnown: true, floating: true, focusHistoryID: 1, at: [0, 0], size: [100, 100]};
        var b = {id: 2, output: "A", workspaceActive: true, geometryKnown: true, floating: true, focusHistoryID: 1, at: [50, 0], size: [100, 100]};
        compare(Policy.canRefract([a, b], "A", true, false, {"1": {}, "2": {}}), false);
        b.focusHistoryID = 0;
        compare(Policy.canRefract([a, b], "A", true, false, {"1": {}, "2": {}}), true);
    }
}

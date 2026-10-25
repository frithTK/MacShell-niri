import QtQuick
import QtTest
import "../../MacShell/WidgetLayout.js" as Layout

TestCase {
    name: "WidgetLayout"
    function values() {
        return {defaults: {tempUnit: "C", locMode: "auto", cityName: "", styles: {clock: "dark", calendar: "liquid"}, mode: "auto"},
                desktopOutput: "main", outputs: {main: {identity: {connector: "DP-1", make: "Demo", model: "Display", serial: "one"}}, other: {identity: {connector: "DP-2", serial: "two"}}}, bindings: {"DP-1": "main"},
                widgets: [{id: "clock", type: "clock", version: 1, output: "main", position: {column: 8, row: 0}, settings: {size: "small"}},
                          {id: "calendar", type: "calendar", version: 1, output: "main", position: {column: 6, row: 0}, settings: {size: "large"}}]};
    }
    function test_saved_display_does_not_follow_screen_order_or_geometry() {
        var state = values(), main = {name: "DP-1", width: 1920, height: 1080}, other = {name: "DP-2", width: 1280, height: 720};
        var outputs = [{name: "DP-1", make: "Demo", model: "Display", serial: "one"}, {name: "DP-2", serial: "two"}];
        compare(Layout.screenFor(state, [main, other], outputs), main);
        compare(Layout.screenFor(state, [other, main], outputs.slice().reverse()), main);
        compare(Layout.screenFor(state, [other], outputs.slice(1)), null);
        var reconnected = {name: "HDMI-A-1", width: 800, height: 600};
        compare(Layout.screenFor(state, [other, reconnected], [{name: "HDMI-A-1", make: "Demo", model: "Display", serial: "one"}, outputs[1]]), reconnected);
    }
    function test_temporary_placement_never_rewrites_desired_cells() {
        var state = values(), before = JSON.stringify(state), wide = {width: 1920, height: 1080};
        var original = Layout.placements(state, wide);
        compare(original.placed.length, 2); compare(original.unplaced.length, 0);
        var small = Layout.placements(state, {width: 400, height: 300});
        compare(small.placed.length, 1); compare(small.unplaced.length, 1);
        verify(small.placed[0].wx !== original.placed[0].wx);
        compare(Layout.placements(state, {width: 160, height: 200}).placed.length, 0);
        compare(Layout.placements(state, null).unplaced.length, 2);
        compare(JSON.stringify(state), before);
        compare(JSON.stringify(Layout.placements(state, wide)), JSON.stringify(original));
    }
    function test_collisions_other_profiles_and_unknown_instances_are_retained() {
        var state = values(); state.widgets[1].position = {column: 8, row: 0}; state.widgets[1].settings.size = "small";
        state.widgets.push({id: "other", type: "clock", version: 1, output: "other", position: {column: 0, row: 0}, settings: {}});
        state.widgets.push({id: "future", type: "clock", version: 99, futureShape: [0, false]});
        state.widgets.push({id: "unknown", type: "agenda", version: 1});
        var before = JSON.stringify(state), plan = Layout.placements(state, {width: 1920, height: 1080});
        compare(plan.placed.length, 2); verify(Math.abs(plan.placed[1].wx - plan.placed[0].wx) >= 185 || Math.abs(plan.placed[1].wy - plan.placed[0].wy) >= 185);
        compare(JSON.stringify(state), before);
    }
    function test_first_add_binds_an_empty_desktop_without_mutating_the_source() {
        var state = values(); state.desktopOutput = ""; state.widgets = [];
        var before = JSON.stringify(state), screen = {name: "DP-2", width: 1920, height: 1080};
        var result = Layout.withDesktop(state, screen, [{name: "DP-2", serial: "two"}]);
        compare(result.desktopOutput, "other"); compare(result.bindings["DP-2"], "other");
        compare(JSON.stringify(state), before); compare(Layout.withDesktop(state, null, []), null);
    }
    function test_inherited_and_explicit_appearance_are_distinct() {
        var state = values(), record = state.widgets[0];
        compare(Layout.settings(record, state.defaults).style, "dark");
        record.settings.style = "liquid"; record.settings.mode = "light";
        compare(Layout.settings(record, state.defaults).style, "liquid");
        compare(Layout.settings(record, state.defaults).mode, "light");
        compare(record.position.row, 0);
    }
}

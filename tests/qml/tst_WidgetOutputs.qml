import QtQuick
import QtTest
import "../../MacShell" as Port
import "../../MacShell/WidgetLayout.js" as Layout
import "../../MacShell/WidgetCatalog.js" as Catalog

TestCase {
    name: "WidgetOutputs"
    function state() {
        return {defaults: {styles: {clock: "dark", calendar: "normal"}, mode: "auto"}, desktopOutput: "main",
                outputs: {main: {identity: {connector: "DP-1", serial: "one"}}, second: {identity: {connector: "DP-2", serial: "two"}}},
                bindings: {"DP-1": "main", "DP-2": "second"},
                widgets: [{id: "a", type: "clock", version: 1, output: "main", position: {column: 0, row: 0}, settings: {size: "small"}},
                          {id: "b", type: "clock", version: 1, output: "second", position: {column: 0, row: 0}, settings: {size: "small"}}]};
    }
    function screens() { return [{name: "DP-1", width: 1920, height: 1080, x: -1920, y: -100, scale: 1}, {name: "DP-2", width: 1280, height: 720, x: 0, y: 0, scale: 1.5}]; }
    function outputs() { return [{name: "DP-1", serial: "one"}, {name: "DP-2", serial: "two"}]; }
    function plan(values, displays, live, reserved) { return Layout.layout(values, Layout.displays(values, displays, live || outputs(), reserved || {})); }
    function assertBounds(rows, displays) {
        rows.forEach(row => {
            var display = displays.find(item => item.name === row.woutput), dims = Catalog.dimensions(row.wsize);
            verify(row.wx >= display.area.x + 21); verify(row.wy >= Math.max(56, display.area.y + 24));
            verify(row.wx + dims[0] <= display.area.x + display.area.width - 21);
            verify(row.wy + dims[1] <= display.area.y + display.area.height - 24);
            verify(!Layout.overlap(row.wx, row.wy, dims, rows.filter(item => item.woutput === row.woutput), row.wid));
        });
    }
    function test_each_output_has_its_own_rows_and_collisions() {
        var values = state(), displays = screens(), before = JSON.stringify(values);
        var result = plan(values, displays);
        compare(result.placed.length, 2); compare(result.unplaced.length, 0);
        compare(result.placed[0].woutput, "DP-1"); compare(result.placed[1].woutput, "DP-2");
        compare(result.placed[0].wprofile, "main"); compare(result.placed[1].wprofile, "second");
        var reversed = plan(values, displays.slice().reverse(), outputs().reverse());
        compare(reversed.placed.find(row => row.wid === "a").wx, result.placed[0].wx);
        displays[0].x = 9000; displays[0].y = 8000; displays[0].scale = 2;
        compare(JSON.stringify(plan(values, displays)), JSON.stringify(result));
        compare(JSON.stringify(values), before);
    }
    function test_disconnect_reconnect_and_connector_change() {
        var values = state(), before = JSON.stringify(values), original = plan(values, screens());
        var absent = plan(values, screens().slice(1), outputs().slice(1));
        compare(absent.placed.length, 1); compare(absent.placed[0].wid, "b");
        compare(absent.unplaced.length, 1); compare(absent.unplaced[0].id, "a"); compare(absent.unplaced[0].display, "DP-1");
        compare(plan(values, [], []).unplaced.length, 2);
        var reconnected = screens(); reconnected[0].name = "HDMI-A-1";
        var live = outputs(); live[0].name = "HDMI-A-1";
        var changed = plan(values, reconnected, live);
        compare(changed.placed.length, 2); compare(changed.placed[0].wprofile, "main"); compare(changed.placed[0].woutput, "HDMI-A-1");
        compare(JSON.stringify(plan(values, screens())), JSON.stringify(original)); compare(JSON.stringify(values), before);
    }
    function test_one_profile_cannot_be_drawn_on_two_outputs() {
        var values = state(); values.bindings["DP-2"] = "main"; values.outputs.main.identity.serial = "";
        var result = Layout.displays(values, screens(), outputs(), {});
        compare(result[0].ambiguous, true); compare(result[1].ambiguous, true);
        compare(result[0].profileId, ""); compare(result[1].profileId, "");
        compare(Layout.layout(values, result).placed.length, 0);
        compare(Layout.withOutput(values, screens()[0], outputs(), screens()), null);
    }
    function test_ambiguous_serial_never_steals_a_saved_layout() {
        var values = state(); delete values.bindings["DP-1"]; delete values.bindings["DP-2"];
        values.outputs.second.identity.serial = "one";
        var live = [{name: "HDMI-1", serial: "one"}, {name: "HDMI-2", serial: "one"}];
        var displays = [{name: "HDMI-1", width: 900, height: 700}, {name: "HDMI-2", width: 900, height: 700}];
        compare(plan(values, displays, live).placed.length, 0);
        compare(Layout.withOutput(values, displays[0], live, displays), null);
    }
    function test_new_output_binding_is_created_only_by_an_explicit_mutation() {
        var values = state(), displays = screens(), before = JSON.stringify(values);
        displays.push({name: "HDMI-1", width: 1280, height: 800});
        var live = outputs().concat([{name: "HDMI-1", serial: "three"}]);
        var plans = Layout.displays(values, displays, live, {});
        compare(plans[2].profileId, ""); compare(plans[2].ambiguous, false); compare(JSON.stringify(values), before);
        var bound = Layout.withOutput(values, displays[2], live, displays);
        verify(bound !== null); compare(bound.values.outputs[bound.profileId].identity.serial, "three");
        compare(bound.values.bindings["HDMI-1"], bound.profileId); compare(bound.values.desktopOutput, "main");
        compare(JSON.stringify(bound.values.widgets), JSON.stringify(values.widgets)); compare(JSON.stringify(values), before);
    }
    function test_reservations_follow_actual_bar_and_dock_exclusive_zones() {
        var bar = {settingsReady: true, barEnabled: true, barHeight: 44};
        var dock = {settingsReady: true, dockEnabled: true, monitor: "DP-2", hideMode: "never", bgHeight: 110, margin: 8};
        compare(Layout.reservedFor("DP-1", bar, dock).bottom, 0);
        compare(Layout.reservedFor("DP-2", bar, dock).bottom, 118);
        for (var mode of ["smart", "always"]) { dock.hideMode = mode; compare(Layout.reservedFor("DP-2", bar, dock).bottom, 0); }
        dock.hideMode = "never"; dock.monitor = ""; compare(Layout.reservedFor("DP-1", bar, dock).bottom, 118);
        bar.barEnabled = false; dock.dockEnabled = false;
        compare(JSON.stringify(Layout.reservedFor("DP-2", bar, dock)), JSON.stringify({top: 0, bottom: 0}));
        bar.barEnabled = true; dock.dockEnabled = true; bar.settingsReady = false; dock.settingsReady = false;
        compare(JSON.stringify(Layout.reservedFor("DP-2", bar, dock)), JSON.stringify({top: 0, bottom: 0}));
    }
    function test_full_grid_reflow_respects_reserved_area_without_saving_it() {
        var values = state(); values.widgets = [];
        for (var i = 0; i < 48; i++) values.widgets.push({id: "w" + i, type: "clock", version: 1, output: i < 24 ? "main" : "second", position: {column: i % 8, row: Math.floor(i / 8) % 3}, settings: {size: i % 5 === 0 ? "large" : "small"}});
        var before = JSON.stringify(values), displays = screens(), original = plan(values, displays);
        var reserved = {"DP-1": {top: 80, bottom: 170}, "DP-2": {top: 70, bottom: 220}};
        var plans = Layout.displays(values, displays, outputs(), reserved), result = Layout.layout(values, plans);
        verify(result.unplaced.length > 0); compare(result.placed.length + result.unplaced.length, 48);
        assertBounds(result.placed, plans);
        compare(JSON.stringify(values), before); compare(JSON.stringify(plan(values, displays)), JSON.stringify(original));
    }
    function test_valid_desired_slots_win_before_overflow_reflow() {
        var values = state(); values.widgets[0].position.column = 100;
        values.widgets[1].output = "main"; values.widgets[1].position.column = 2;
        var displays = [{name: "DP-1", width: 800, height: 700}];
        var result = plan(values, displays), g = Layout.grid(800, 700);
        compare(result.placed.find(item => item.wid === "b").wx, g.left + 2 * g.pitchX);
        var a = result.placed.find(item => item.wid === "a"), b = result.placed.find(item => item.wid === "b");
        verify(a.wx !== b.wx || a.wy !== b.wy);
    }
    function test_rotation_fractional_geometry_and_tiny_reserved_screen_data() {
        return [{tag: "portrait", width: 720, height: 1280}, {tag: "fractional logical", width: 853.333, height: 479.666},
                {tag: "tiny", width: 200, height: 160}, {tag: "zero", width: 0, height: 0}, {tag: "reserved fully", width: 1920, height: 1080, top: 900, bottom: 900}];
    }
    function test_rotation_fractional_geometry_and_tiny_reserved_screen(data) {
        var values = state(), before = JSON.stringify(values), display = {name: "DP-1", width: data.width, height: data.height};
        var plans = Layout.displays(values, [display], outputs().slice(0, 1), {"DP-1": {top: data.top || 44.2, bottom: data.bottom || 77.3}});
        var result = Layout.layout(values, plans);
        assertBounds(result.placed, plans);
        if (data.width <= 200 || data.top) compare(result.placed.length, 0);
        compare(result.placed.length + result.unplaced.length, 2); compare(JSON.stringify(values), before);
    }
    Component { id: modelComponent; Port.WidgetModel {} }
    function test_filtered_model_clears_only_the_moved_output_and_preserves_other_delegates() {
        var model = createTemporaryObject(modelComponent, null, {rows: [{wid: "a", wx: 1}, {wid: "b", wx: 2}]});
        compare(model.count, 2); var retained = model.get(1);
        model.rows = [{wid: "b", wx: 2}]; compare(model.count, 1); compare(model.get(0), retained);
        model.rows = []; compare(model.count, 0);
    }
}

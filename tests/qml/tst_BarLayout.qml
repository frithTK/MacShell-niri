import QtQuick
import QtTest
import "../../MacShell" as Port
import "../../MacShell/BarLayout.js" as Layout
import "../../MacShell/OutputProfiles.js" as Outputs

TestCase {
    id: test; name: "BarLayout"; when: windowShown
    width: 800; height: 2200; visible: true
    property var catalog: [
        {type: "appleMenu", label: "Apple menu", zone: "left", priority: 95, width: 30},
        {type: "appMenus", label: "Application menus", zone: "left", priority: 35, width: 400, compact: 100},
        {type: "workspaces", label: "Workspaces", zone: "center", priority: 80, width: 110, compact: 22},
        {type: "volume", label: "Volume", zone: "right", priority: 75, width: 28},
        {type: "clock", label: "Clock", zone: "right", priority: 90, width: 150, compact: 72},
        {type: "spacer", label: "Spacer", zone: "right", priority: 0, width: 16, repeatable: true}
    ]
    QtObject {
        id: backend
        property bool ready: true
        property bool pending: false
        property bool readOnly: false
        property bool canRecover: false
        property bool needsRepair: false
        property bool migrationPending: false
        property real widgetScale: 1
        property string notice: ""
        property string error: ""
        property string token: "initial"
        property var catalog: test.catalog
        property var values: ({})
        property int saves: 0
        property var outputs: [{name: "DP-1", make: "Demo", model: "Display", serial: "one", logicalRect: {x: -1280, y: 0, width: 1280, height: 720}, scale: 1.5, transform: "90"}, {name: "DP-2", make: "Demo", model: "Display", serial: "two"}]
        signal finished(bool success)
        function refresh() { }
        function save(next, expected) { saves++; if (expected !== token) { finished(false); return; } values = Layout.clone(next); token = "saved" + saves; finished(true); }
        function recover(expected) { }
    }
    Component { id: editorComponent; Port.BarLayoutEditor { controller: backend; width: 580 } }
    function init() {
        backend.values = {common: Layout.defaults(catalog), outputs: {}, bindings: {}};
        backend.outputs = [{name: "DP-1", make: "Demo", model: "Display", serial: "one", logicalRect: {x: -1280, y: 0, width: 1280, height: 720}, scale: 1.5, transform: "90"}, {name: "DP-2", make: "Demo", model: "Display", serial: "two"}];
        backend.token = "initial"; backend.saves = 0; backend.readOnly = false; backend.pending = false;
    }
    function test_widths_scales_long_titles_and_dynamic_tray_are_stable() {
        var all = catalog.concat([{type: "tray", label: "Tray", zone: "right", priority: 30, width: 260}, {type: "monitoring", label: "Activity", zone: "right", priority: 65, width: 120, compact: 26}]);
        var layout = Layout.defaults(all);
        for (var width of [240, 800, 1366, 1920]) for (var scale of [1, 1.25, 1.5]) for (var tray of [0, 26, 520]) {
            var measurements = {appMenus: {preferred: 1400, forms: [1400, 100]}, tray: {preferred: tray, available: tray > 0}};
            var plan = Layout.solve(layout, all, measurements, width / scale);
            compare(JSON.stringify(plan), JSON.stringify(Layout.solve(layout, all, measurements, width / scale)));
            var boxes = Object.keys(plan.items).map(key => plan.items[key]).filter(item => item.width > 0).sort((a, b) => a.x - b.x);
            var end = 0;
            boxes.forEach(item => { verify(item.x >= end - .001, "overlap at " + width + "/" + scale); verify(item.x + item.width <= width / scale + .001); end = item.x + item.width; });
            if (plan.overflow.length) { verify(plan.overflowX >= end); verify(plan.overflowX + plan.overflowWidth <= width / scale); }
        }
        compare(Layout.solve([], catalog, {}, 800).overflow.length, 0);
        var special = Layout.solve([{id: "__proto__", type: "clock", zone: "left", enabled: true, priority: 90}], catalog, {}, 800);
        compare(special.items["__proto__"].width, 150);
        var tiny = Layout.solve(layout, all, {}, 20);
        compare(tiny.overflowX, 0); compare(tiny.overflowWidth, 20);
    }
    function test_output_identity_is_independent_of_list_order_and_geometry() {
        var profiles = {one: {identity: Outputs.identity(backend.outputs[0]), layout: []}};
        compare(Outputs.resolve(profiles, backend.outputs[0], backend.outputs).id, "one");
        compare(Outputs.resolve(profiles, backend.outputs[0], backend.outputs.slice().reverse()).id, "one");
        compare(Outputs.resolve(profiles, Object.assign({}, backend.outputs[0], {name: "HDMI-A-1"}), [Object.assign({}, backend.outputs[0], {name: "HDMI-A-1"})]).id, "one");
        compare(Outputs.resolve(profiles, Object.assign({}, backend.outputs[0], {serial: "other"}), backend.outputs).id, "");
        profiles.two = {identity: Outputs.identity(backend.outputs[0]), layout: []};
        compare(Outputs.resolve(profiles, backend.outputs[0], backend.outputs).ambiguous, true);
        compare(Outputs.resolve(profiles, backend.outputs[0], backend.outputs, {"DP-1": "two"}).id, "two");
        compare(Outputs.effective({common: ["common"], outputs: profiles}, {name: "other"}, []).join(), "common");
    }
    function test_move_cancel_and_apply_use_a_draft() {
        var item = createTemporaryObject(editorComponent, test);
        waitForRendering(item);
        mouseClick(findChild(item, "barItem_appleMenu"));
        compare(item.selectedId, "appleMenu"); waitForRendering(item);
        mouseClick(findChild(item, "barLater"));
        compare(item.entries.filter(entry => entry.zone === "left")[0].type, "appMenus");
        compare(backend.values.common[0].type, "appleMenu"); compare(backend.saves, 0);
        mouseClick(findChild(item, "barCancel")); compare(item.dirty, false);
        item.move("volume", "left", 0); item.change("volume", "priority", 100);
        waitForRendering(item); mouseClick(findChild(item, "barApply"));
        compare(backend.saves, 1); compare(backend.values.common[0].type, "volume"); compare(item.dirty, false);
    }
    function test_profile_customize_inherit_and_disconnect_preserve_other_profiles() {
        backend.values.outputs = {offline: {identity: {connector: "old", serial: "old"}, layout: []}};
        var item = createTemporaryObject(editorComponent, test);
        item.advanced = true;
        item.scope = "live:DP-1"; compare(item.inherited, true);
        waitForRendering(item); mouseClick(findChild(item, "barCustomize"));
        compare(item.inherited, false); var key = item.profileId;
        item.replaceEntries([]);
        compare(item.draft.outputs[key].layout.length, 0);
        compare(item.draft.outputs.offline.layout.length, 0);
        compare(Object.keys(backend.values.outputs).length, 1);
        item.inherit(); verify(item.draft.outputs[key].layout === undefined);
        compare(item.entries.length, backend.values.common.length);
        item.scope = "saved:offline"; compare(item.entries.length, 0);
        item.scope = "live:DP-1";
        backend.outputs = [backend.outputs[1]];
        tryCompare(item, "scope", "common");
        verify(item.draft.outputs[key] !== undefined); verify(item.draft.outputs.offline !== undefined);
        compare(backend.saves, 0);
    }
    function test_conflict_preserves_draft_until_reload() {
        var item = createTemporaryObject(editorComponent, test);
        item.change("volume", "enabled", false);
        backend.values = {common: [], outputs: {}, bindings: {}}; backend.token = "external";
        compare(item.conflict, true); verify(item.entries.length > 0);
        compare(findChild(item, "barApply").enabled, false);
        waitForRendering(item); mouseClick(findChild(item, "barReload"));
        compare(item.entries.length, 0); compare(item.dirty, false); compare(backend.saves, 0);
    }
    function test_priority_keeps_the_focused_control_alive() {
        var item = createTemporaryObject(editorComponent, test);
        item.advanced = true; item.selectedId = "volume";
        waitForRendering(item);
        var control = findChild(item, "barSelectedPriority");
        control.forceActiveFocus(); keyClick(Qt.Key_Up); wait(20);
        compare(findChild(item, "barSelectedPriority"), control);
        keyClick(Qt.Key_Up); wait(20);
        compare(item.entries.find(entry => entry.id === "volume").priority, 77);
        compare(backend.values.common.find(entry => entry.id === "volume").priority, 75);
    }
    function test_drag_to_an_empty_zone_and_keyboard_zone_choice() {
        backend.values = {common: [{id: "volume", type: "volume", zone: "left", enabled: true, priority: 75}], outputs: {}, bindings: {}};
        var item = createTemporaryObject(editorComponent, test);
        waitForRendering(item);
        var handle = findChild(item, "barDrag_volume"), zone = findChild(item, "barDropZone_center");
        var point = zone.mapToItem(handle, zone.width / 2, zone.height / 2);
        mousePress(handle, handle.width / 2, handle.height / 2);
        mouseMove(handle, handle.width / 2 + 20, handle.height / 2 + 20, 50);
        mouseMove(handle, point.x, point.y, 50);
        wait(50);
        mouseRelease(handle, point.x, point.y);
        tryVerify(() => item.entries[0].zone === "center");
        compare(backend.values.common[0].zone, "left");
        waitForRendering(item);
        var choice = findChild(item, "barSelectedZone");
        choice.forceActiveFocus(); keyClick(Qt.Key_Space); keyClick(Qt.Key_End); keyClick(Qt.Key_Return);
        tryVerify(() => item.entries[0].zone === "right");
    }
    function test_popup_coordinates_account_for_scale_and_transform_origin() {
        for (var scale of [.9, 1, 1.25]) for (var origin of [0, .5, 1]) for (var anchor of [0, 400, 800]) {
            var x = Layout.popupX(anchor, 300, scale, origin, 800, false);
            var actual = x + 300 * (1 - scale) * origin;
            verify(actual >= 6 - .001); verify(actual + 300 * scale <= 794 + .001);
        }
    }
    function test_drop_after_a_row_has_no_index_shift() {
        backend.values = {common: [{id: "volume", type: "volume", zone: "left", enabled: true, priority: 75}, {id: "clock", type: "clock", zone: "left", enabled: true, priority: 90}], outputs: {}, bindings: {}};
        var item = createTemporaryObject(editorComponent, test);
        function dragNear(id, target, after) {
            waitForRendering(item);
            var handle = findChild(item, "barDrag_" + id), area = findChild(item, "barDropOn_" + target);
            var point = area.mapToItem(handle, after ? area.width - 5 : 5, area.height / 2);
            mousePress(handle, handle.width / 2, handle.height / 2); mouseMove(handle, handle.width / 2 + 20, handle.height / 2 + 20, 50); mouseMove(handle, point.x, point.y, 50); wait(50); mouseRelease(handle, point.x, point.y); wait(50);
        }
        dragNear("clock", "volume", true);
        compare(item.entries.map(entry => entry.id).join(), "volume,clock"); compare(item.dirty, false);
        dragNear("volume", "clock", true);
        tryVerify(() => item.entries[0].id === "clock"); compare(item.dirty, true); compare(backend.saves, 0);
        dragNear("volume", "clock", false);
        tryVerify(() => item.entries[0].id === "volume"); compare(item.dirty, false);
    }
    function test_simple_view_hide_and_add_restore_the_same_item() {
        var item = createTemporaryObject(editorComponent, test);
        waitForRendering(item);
        compare(findChild(item, "barLayoutScope").visible, false);
        compare(findChild(item, "barPreviewWidth").visible, false);
        mouseClick(findChild(item, "barItem_volume"));
        compare(item.selectedId, "volume"); waitForRendering(item);
        mouseClick(findChild(item, "barHide"));
        tryVerify(() => findChild(item, "barItem_volume") === null);
        compare(item.entries.find(entry => entry.id === "volume").enabled, false);
        waitForRendering(item);
        mouseClick(findChild(item, "barAdd"));
        waitForRendering(item);
        var popup = findChild(item, "barAddPopup"); tryCompare(popup, "opened", true);
        var addVolume = findChild(popup.contentItem, "barAdd_volume"); verify(addVolume !== null);
        mouseClick(addVolume);
        tryVerify(() => findChild(item, "barItem_volume") !== null);
        compare(item.entries.filter(entry => entry.type === "volume").length, 1);
        compare(item.entries.find(entry => entry.id === "volume").priority, 75);
        compare(item.dirty, false); compare(backend.saves, 0);
    }
    function test_keyboard_reorder_keeps_focus_and_spacers_are_removable() {
        var item = createTemporaryObject(editorComponent, test);
        waitForRendering(item);
        var chip = findChild(item, "barItem_appleMenu"); chip.forceActiveFocus(); keyClick(Qt.Key_Right);
        tryCompare(item, "dirty", true); compare(chip.activeFocus, true);
        compare(item.entries.filter(entry => entry.zone === "left")[1].id, "appleMenu");
        item.add("spacer"); var first = item.selectedId;
        item.add("spacer"); verify(item.selectedId !== first);
        item.hideSelected();
        compare(item.entries.filter(entry => entry.type === "spacer").length, 1);
        compare(backend.saves, 0);
    }
    function test_add_menu_supports_keyboard_and_advanced_keeps_the_draft() {
        backend.values = {common: [], outputs: {}, bindings: {}};
        var item = createTemporaryObject(editorComponent, test);
        waitForRendering(item); mouseClick(findChild(item, "barAdd"));
        var popup = findChild(item, "barAddPopup"); tryCompare(popup, "opened", true);
        var first = findChild(popup.contentItem, "barAdd_appleMenu"); tryCompare(first, "activeFocus", true);
        keyClick(Qt.Key_Return);
        tryCompare(popup, "visible", false); compare(item.entries[0].type, "appleMenu");
        waitForRendering(item); mouseClick(findChild(item, "barAdvanced"));
        compare(findChild(item, "barLayoutScope").visible, true);
        mouseClick(findChild(item, "barAdvanced"));
        compare(findChild(item, "barLayoutScope").visible, false);
        compare(item.dirty, true); compare(item.entries[0].type, "appleMenu"); compare(backend.saves, 0);
    }
}

import QtQuick
import QtTest
import "../../MacShell" as Port
import "../../MacShell/BatteriesData.js" as Data
import "../../MacShell/BatteryState.js" as BatteryState

TestCase {
    id: test
    name: "BatteriesWidget"; when: windowShown
    width: 720; height: 1300; visible: true
    readonly property string firstId: "bluetooth:AA:BB:CC:DD:EE:01"
    readonly property string secondId: "bluetooth:AA:BB:CC:DD:EE:02"
    Component { id: cardComponent; Port.BatteriesWidget { style: "normal"; size: "large" } }
    Component { id: modelComponent; Port.BatteriesModel {} }
    Component { id: editorComponent; Port.WidgetAppearanceEditor { width: 520; controller: backend } }
    QtObject {
        id: laptop
        property var widgetData: ({present: true, ready: true, percentage: 84, charging: true})
    }
    QtObject {
        id: bluetooth
        property bool stateReady: true
        property bool available: true
        property bool enabled: true
        property var devices: []
    }
    QtObject {
        id: backend
        property bool settingsEditable: true
        property var batteryDevices: ({entries: []})
        property var call: []
        signal mutationFinished(bool success)
        function commitWidgetAppearance(id, draft, baseline, type) { call = [id, draft, baseline, type]; return true; }
    }
    function device(address, extra) {
        return Object.assign({address: address, path: "/org/bluez/hci0/dev_" + address.replace(/:/g, "_"),
            name: "Same name", icon: "input-keyboard", adapterEnabled: true, connected: true, battery: 0}, extra || {});
    }
    function normalized(devices, state, old) {
        return Data.normalize(null, devices, state || {ready: true, available: true, enabled: true}, old || []);
    }
    function init() {
        laptop.widgetData = {present: true, ready: true, percentage: 84, charging: true};
        bluetooth.stateReady = true; bluetooth.available = true; bluetooth.enabled = true; bluetooth.devices = [];
        backend.call = []; backend.settingsEditable = true; backend.batteryDevices = {entries: []};
    }
    function test_laptop_readiness_unknown_zero_and_full() {
        compare(BatteryState.chargePercentage(true, false, 0), -1);
        compare(BatteryState.chargePercentage(false, true, .5), -1);
        for (var invalid of [NaN, Infinity, -1, null, undefined, 2, "0"]) compare(BatteryState.chargePercentage(true, true, invalid), -1);
        compare(BatteryState.chargePercentage(true, true, 0), 0);
        compare(BatteryState.chargePercentage(true, true, 1), 100);
        var model = createTemporaryObject(modelComponent, test, {battery: laptop, active: true});
        compare(model.entries[0].percentage, 84); compare(Data.status(model.entries[0]), "Charging");
        laptop.widgetData = {present: true, ready: false, percentage: 0}; compare(model.entries[0].percentage, -1);
        laptop.widgetData = {present: true, ready: true, percentage: 0}; compare(model.entries[0].percentage, 0);
        laptop.widgetData = {present: true, ready: true, percentage: 100, full: true}; compare(Data.status(model.entries[0]), "Fully charged");
    }
    function test_addresses_are_stable_across_aliases_adapters_and_order() {
        var a = device("aa:bb:cc:dd:ee:01"), b = device("AA:BB:CC:DD:EE:02", {battery: 100});
        var rows = normalized([a, b]); compare(rows.length, 2); compare(rows[0].id, firstId); compare(rows[1].id, secondId);
        verify(rows[0].label !== rows[1].label);
        var moved = Object.assign({}, a, {name: "Renamed", path: "/org/bluez/hci3/dev_AA_BB_CC_DD_EE_01"});
        compare(Data.deviceId(moved), firstId);
        var copy = Object.assign({}, a, {adapterEnabled: false, connected: false, battery: 99});
        rows = normalized([copy, moved, b]); compare(rows.length, 2);
        compare(rows.find(row => row.id === firstId).percentage, 0);
        compare(normalized([b, moved, copy]).find(row => row.id === firstId).percentage, 0);
        compare(Data.deviceId({path: "/org/bluez/hci9/dev_AA_BB_CC_DD_EE_01"}), firstId);
    }
    function test_disconnection_power_and_service_loss_never_show_cached_charge() {
        var original = device("AA:BB:CC:DD:EE:01", {battery: 76});
        var rows = normalized([original]); compare(Data.value(rows[0]), "76%");
        for (var extra of [{connected: false}, {adapterEnabled: false}, {blocked: true}]) {
            var current = normalized([Object.assign({}, original, extra)], undefined, rows);
            compare(current[0].percentage, -1); compare(Data.value(current[0]), "—");
            verify(Data.status(current[0]) !== "");
        }
        rows = normalized([original], {ready: false, available: true, enabled: true}, rows);
        compare(rows[0].status, "unavailable"); compare(rows[0].percentage, -1);
        rows = normalized([original], {ready: true, available: true, enabled: false}, rows);
        compare(Data.status(rows[0]), "Bluetooth off"); compare(Data.value(rows[0]), "—");
    }
    function test_removed_device_keeps_identity_and_selection_then_recovers() {
        var settings = {mode: "selected", devices: [firstId]};
        var first = normalized([device("AA:BB:CC:DD:EE:01", {battery: 45})]);
        var gone = normalized([], undefined, first);
        compare(gone[0].label, first[0].label); compare(gone[0].present, false);
        compare(Data.rows(gone, settings)[0].id, firstId); compare(Data.rows(gone, settings)[0].percentage, -1);
        compare(Data.rows(gone, {}).length, 0);
        var restored = normalized([device("AA:BB:CC:DD:EE:01", {battery: 19})], undefined, gone);
        compare(restored.length, 1); compare(Data.rows(restored, settings)[0].percentage, 19);
        compare(Data.rows([], settings)[0].id, firstId);
    }
    function test_inactive_model_freezes_and_resumes_without_polling() {
        var model = createTemporaryObject(modelComponent, test, {battery: laptop, bluetooth: bluetooth, active: true});
        compare(model.entries.length, 1);
        model.active = false;
        laptop.widgetData = {present: false}; bluetooth.devices = [device("AA:BB:CC:DD:EE:01", {battery: 51})];
        compare(model.entries[0].percentage, 84);
        model.active = true;
        compare(model.entries.find(row => row.id === firstId).percentage, 51);
        compare(Data.rows(model.entries, {}).length, 1);
    }
    function test_auto_selected_empty_and_capacity_are_explicit() {
        var entries = Data.demoEntries();
        var card = createTemporaryObject(cardComponent, test, {entries: entries}); waitForRendering(card);
        compare(card.devices.length, 6); compare(card.shownDevices.length, 6);
        card.size = "small"; compare(card.shownDevices.length, 2); compare(card.shownDevices[0].id, "laptop");
        compare(card.shownDevices[1].kind, "headphones"); compare(findChild(card, "batteriesFooter").text, "+4 more devices");
        card.size = "medium"; compare(card.shownDevices.length, 4);
        card.settings = {mode: "selected", devices: []}; compare(card.devices.length, 0); compare(findChild(card, "batteriesEmpty").text, "No devices selected");
        card.settings = {}; card.entries = []; compare(findChild(card, "batteriesEmpty").text, "No batteries available");
    }
    function test_computer_without_laptop_battery_and_bluetooth_has_no_phantom_zero() {
        laptop.widgetData = {present: false, ready: true, percentage: 0};
        bluetooth.available = false; bluetooth.enabled = false;
        var model = createTemporaryObject(modelComponent, test, {battery: laptop, bluetooth: bluetooth, active: true});
        var card = createTemporaryObject(cardComponent, test, {entries: Qt.binding(() => model.entries)});
        waitForRendering(card); compare(card.devices.length, 0); compare(findChild(card, "batteriesEmpty").visible, true);
        card.settings = {mode: "selected", devices: ["laptop"]};
        compare(card.devices[0].percentage, -1); compare(Data.value(card.devices[0]), "—");
    }
    function test_zero_unknown_full_and_aliases_are_plain_text() {
        var entries = normalized([device("AA:BB:CC:DD:EE:01", {name: "<b>Keyboard</b>", battery: 0}), device("AA:BB:CC:DD:EE:02", {battery: -1})]);
        var card = createTemporaryObject(cardComponent, test, {entries: entries}); waitForRendering(card);
        compare(findChild(card, "batteryValue_" + firstId).text, "0%");
        compare(findChild(card, "batteryValue_" + secondId).text, "—");
        compare(findChild(card, "batteryStatus_" + secondId).text, "Battery unknown");
        compare(findChild(card, "batteryName_" + firstId).textFormat, Text.PlainText);
    }
    function test_choice_draft_cancel_apply_and_unknown_fields() {
        backend.batteryDevices = {entries: Data.normalize(laptop.widgetData, [device("AA:BB:CC:DD:EE:01")], {ready: true, available: true, enabled: true}, [])};
        var record = {id: "chosen", type: "batteries", supported: true, size: "small", style: "normal", defaultStyle: "liquid", mode: "auto",
            savedSettings: {batteries: {mode: "selected", devices: ["laptop"], future: {keep: false}}, extra: 0}};
        var editor = createTemporaryObject(editorComponent, test, {record: record}); waitForRendering(editor);
        var preview = findChild(editor, "widgetAppearancePreview"); compare(preview.visual.devices.length, 1);
        mouseClick(findChild(editor, "widgetBatteryDevice_" + firstId));
        compare(editor.batteryIds.length, 2); compare(preview.visual.devices.length, 2); compare(backend.call.length, 0);
        mouseClick(findChild(editor, "widgetAppearanceCancel")); compare(editor.batteryIds.join(), "laptop"); compare(backend.call.length, 0);
        editor.toggleBattery(firstId); editor.change("textScale", 1.2); editor.apply();
        compare(backend.call[0], "chosen"); compare(backend.call[3], "batteries");
        compare(backend.call[1].batteries.devices.join(), "laptop," + firstId);
        compare(backend.call[1].batteries.future.keep, false); compare(backend.call[1].extra, 0);
        compare(record.savedSettings.batteries.devices.join(), "laptop");
        backend.mutationFinished(false); verify(editor.dirty); verify(editor.error !== "");
    }
    function test_apple_parts_stay_when_advertised_in_the_case() {
        var rows = normalized([device("AA:BB:CC:DD:EE:01", {name: "AirPods", icon: "audio-headphones",
            battery: -1, batteryLeft: 80, batteryRight: 70, batteryCase: 50, charging: true})]);
        compare(rows[0].percentage, 70); compare(rows[0].left, 80); compare(rows[0].right, 70); compare(rows[0].caseCharge, 50);
        compare(Data.value(rows[0]), "70%"); compare(Data.status(rows[0]), "L 80% · R 70% · Case 50%");
        var card = createTemporaryObject(cardComponent, test, {entries: rows}); waitForRendering(card);
        compare(findChild(card, "batteryStatus_" + firstId).text, "L 80% · R 70% · Case 50%");
        verify(findChild(card, "batteryDevice_" + firstId));
        rows = normalized([device("AA:BB:CC:DD:EE:01", {name: "AirPods", icon: "audio-headphones",
            battery: -1, batteryLeft: 80, batteryRight: 70, batteryCase: 50, connected: false})], undefined, rows);
        compare(rows[0].percentage, 70); compare(rows[0].left, 80); compare(rows[0].right, 70); compare(rows[0].caseCharge, 50);
        compare(Data.value(rows[0]), "70%"); compare(Data.status(rows[0]), "Disconnected");
        compare(Data.rows(rows, {}).length, 1);
    }
    function test_small_auto_keeps_headphones_with_charge_beside_the_laptop() {
        var laptop = Data.normalize({present: true, ready: true, percentage: 84}, [], {ready: true, available: true, enabled: true}, [])[0];
        var airpods = normalized([device("AA:BB:CC:DD:EE:01", {name: "AirPods", icon: "audio-headphones",
            connected: true, battery: 100})])[0];
        var mouse = normalized([device("AA:BB:CC:DD:EE:02", {name: "Mouse", icon: "input-mouse",
            connected: true, battery: 42})])[0];
        var entries = [laptop, mouse, airpods];
        compare(Data.pickShown(entries, {}, 2).map(row => row.kind).join(), "laptop,headphones");
        var card = createTemporaryObject(cardComponent, test, {entries: entries, size: "small", settings: {}});
        waitForRendering(card);
        compare(card.shownDevices.length, 2); compare(card.shownDevices[0].id, "laptop");
        compare(card.shownDevices[1].kind, "headphones"); compare(findChild(card, "batteryValue_" + firstId).text, "100%");
        var cased = normalized([device("AA:BB:CC:DD:EE:01", {name: "AirPods", icon: "audio-headphones",
            connected: false, battery: -1, batteryLeft: 88, batteryRight: 90, batteryCase: 40})])[0];
        var idleMouse = normalized([device("AA:BB:CC:DD:EE:02", {name: "Mouse", icon: "input-mouse",
            connected: false, battery: 12})])[0];
        entries = [laptop, idleMouse, cased];
        compare(Data.rows(entries, {}).map(row => row.kind).join(), "laptop,headphones");
        compare(Data.pickShown(entries, {}, 2).map(row => row.kind).join(), "laptop,headphones");
        card.entries = entries; waitForRendering(card);
        compare(card.shownDevices[1].id, firstId); compare(findChild(card, "batteryValue_" + firstId).text, "88%");
        compare(findChild(card, "batteryStatus_" + firstId).text, "Disconnected");
    }
    function test_invalid_ids_modes_and_duplicates_are_rejected() {
        for (var value of [null, [], {devices: "laptop"}, {mode: "other"}, {devices: ["laptop", "laptop"]}, {devices: [null]},
            {devices: ["bluetooth:aa:bb:cc:dd:ee:01"]}, {devices: ["other"]}, {devices: Array(17).fill("laptop")}]) compare(Data.validSettings(value), false);
        compare(Data.validSettings({mode: "selected", devices: [], future: 0}), true);
        compare(Data.validSettings({devices: ["laptop", firstId]}), true);
    }
}

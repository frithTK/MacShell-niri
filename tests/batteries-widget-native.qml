// Injected into the real shell with isolated battery/Bluetooth inputs.
property int batteriesPhase: 0
property int batteriesWaits: 0
property int batteriesCycles: 0
property string batteriesOutput: ""
property string batteriesCopy: ""
property string batteriesFrozen: ""
property string batteriesToken: ""
readonly property string batteriesFirst: "bluetooth:AA:BB:CC:DD:EE:01"
readonly property string batteriesSecond: "bluetooth:AA:BB:CC:DD:EE:02"
function batteriesCheck(value, reason) { if (!value) throw new Error("BATTERIES_WIDGET_FAIL phase " + batteriesPhase + ": " + reason); }
function batteriesFind(item, name) {
    if (!item) return null;
    if (item.objectName === name) return item;
    for (var child of item.children || []) { var result = batteriesFind(child, name); if (result) return result; }
    return null;
}
function batteriesVisual() {
    var window = macWidgets.desktopWindows[batteriesOutput];
    return window ? batteriesFind(window.contentItem, "widgetVisual_" + macWidgets.renderedRows[0].wid) : null;
}
function batteriesDevice(address, charge, extra) {
    return Object.assign({address: address, path: "/org/bluez/hci0/dev_" + address.replace(/:/g, "_"),
        name: "Same name", icon: "input-mouse", connected: true, adapterEnabled: true, battery: charge}, extra || {});
}
Window {
    id: batteriesMirrorWindow
    width: 185; height: 185; visible: true; flags: Qt.Tool | Qt.WindowDoesNotAcceptFocus
    WidgetVisual {
        id: batteriesMirror; anchors.fill: parent; host: macWidgets; mirror: true
        readonly property var row: macWidgets.renderedRows[0] || null
        instanceId: row ? row.wid : ""; wtype: "batteries"; wstyle: "normal"
        sname: row ? row.woutput : ""; wbatteries: row ? row.wbatteries : "{}"
        renderActive: !!row && macWidgets.outputActive(sname)
    }
}
Window {
    width: 580; height: 900; visible: batteriesPhase >= 16 && batteriesPhase <= 19
    flags: Qt.Tool | Qt.WindowDoesNotAcceptFocus
    WidgetAppearanceEditor {
        id: batteriesEditor; width: 530; x: 24; y: 24; controller: macWidgets
        record: macWidgets.instanceRows[0] || null
    }
}
Timer {
    interval: 140; repeat: true; running: true
    onTriggered: {
        if (++batteriesWaits > 360) { console.error("BATTERIES_WIDGET_FAIL timeout phase " + batteriesPhase); Qt.exit(1); return; }
        if (!macBar.settingsReady || !macDock.settingsReady || !macWidgets.ready || macWidgets.pending) return;
        try {
            var phase = batteriesPhase, model = macWidgets.batteryDevices, state = macWidgets.resourceState();
            batteriesCheck(!macBar.bluetooth.discovering && !macBar.bluetooth.busy, "no discovery or device action");
            if (phase === 0) {
                batteriesCheck(!model.active, "no model updates without views");
                macBar.bluetooth.stateReady = true; macBar.bluetooth.available = true; macBar.bluetooth.enabled = true;
                macBar.bluetooth.devices = [batteriesDevice("AA:BB:CC:DD:EE:01", 0), batteriesDevice("AA:BB:CC:DD:EE:02", 100),
                    batteriesDevice("AA:BB:CC:DD:EE:03", -1, {name: "Headphones", icon: "audio-headphones"}),
                    batteriesDevice("AA:BB:CC:DD:EE:01", 99, {path: "/org/bluez/hci1/dev_AA_BB_CC_DD_EE_01", connected: false})];
                batteriesOutput = macWidgets.displayChoices[0].name;
                batteriesCheck(macWidgets.addWidget("batteries", "normal", "small", batteriesOutput), "add Small");
            } else if (phase === 1) {
                batteriesCheck(macWidgets.addWidget("batteries", "liquid", "medium", batteriesOutput), "add Medium");
            } else if (phase === 2) {
                batteriesCheck(macWidgets.addWidget("batteries", "normal", "large", batteriesOutput), "add Large");
            } else if (phase === 3) {
                batteriesCheck(state.sources.batteries === 3 && state.consumers.length === 3 && state.activeViews >= 4, "mirror shares per-ID subscription");
                batteriesCheck(model.entries.length === 4, "one laptop and three unique Bluetooth devices");
                batteriesCheck(model.entries.find(row => row.id === batteriesFirst).percentage === 0, "zero is live, stale duplicate rejected");
                batteriesCheck(model.entries.find(row => row.id === batteriesSecond).percentage === 100, "full Bluetooth battery");
                batteriesCheck(!batteriesVisual().interactive && !batteriesMirror.interactive, "passive desktop and mirror");
                var row = macWidgets.instanceRows[0], draft = JSON.parse(JSON.stringify(row.savedSettings));
                draft.batteries = {mode: "selected", devices: ["laptop", batteriesFirst, batteriesSecond], future: {keep: false}};
                batteriesCheck(macWidgets.commitWidgetAppearance(row.id, draft, row.savedSettings, "batteries"), "atomic device Apply");
            } else if (phase === 4) {
                batteriesCheck(batteriesVisual().visual.devices.length === 3 && batteriesMirror.visual.devices.length === 3, "selected devices match desktop and mirror");
                var row = macWidgets.instanceRows[0];
                batteriesCheck(!macWidgets.commitWidgetAppearance(row.id, {batteries: {devices: ["invalid"]}}, row.savedSettings, "batteries"), "invalid ID rejected");
                batteriesCheck(!macWidgets.commitWidgetAppearance(row.id, row.savedSettings, {}, "batteries"), "conflict rejected");
                batteriesCheck(macWidgets.duplicateWidget(row.id), "duplicate");
            } else if (phase === 5) {
                batteriesCheck(state.sources.batteries === 4, "four cards share the source model");
                batteriesCopy = macWidgets.instanceRows[1].id;
                batteriesCheck(macWidgets.instanceRows[1].savedSettings.batteries.future.keep === false, "duplicate retains extension");
                var row = macWidgets.instanceRows[0], draft = JSON.parse(JSON.stringify(row.savedSettings));
                draft.batteries.devices = ["laptop", batteriesFirst];
                batteriesCheck(macWidgets.commitWidgetAppearance(row.id, draft, row.savedSettings, "batteries"), "change only original");
            } else if (phase === 6) {
                batteriesCheck(macWidgets.instanceRows[1].savedSettings.batteries.devices.length === 3, "duplicate selection is independent");
                batteriesCheck(macWidgets.removeWidget(batteriesCopy), "remove duplicate");
            } else if (phase === 7) {
                macBar.bluetooth.devices = [batteriesDevice("AA:BB:CC:DD:EE:02", 100)];
                macBar.battery.testReady = false;
            } else if (phase === 8) {
                batteriesCheck(batteriesVisual().visual.devices[0].percentage === -1, "unready laptop is unknown");
                batteriesCheck(batteriesVisual().visual.devices[1].id === batteriesFirst && batteriesVisual().visual.devices[1].percentage === -1, "vanished selection retained without cached charge");
                macBar.bluetooth.enabled = false;
                macBar.battery.testReady = true; macBar.battery.fraction = 1; macBar.battery.full = true;
            } else if (phase === 9) {
                batteriesCheck(model.entries.find(row => row.id === batteriesSecond).status === "off", "Bluetooth off is explicit");
                batteriesCheck(batteriesVisual().visual.devices[0].percentage === 100, "full laptop battery");
                macBar.bluetooth.enabled = true;
                macBar.bluetooth.devices = [batteriesDevice("AA:BB:CC:DD:EE:01", 52, {path: "/org/bluez/hci3/dev_AA_BB_CC_DD_EE_01"}), batteriesDevice("AA:BB:CC:DD:EE:02", 100)];
            } else if (phase === 10) {
                batteriesCheck(batteriesVisual().visual.devices[1].percentage === 52, "same identity restored on a new adapter");
                macBar.bluetooth.stateReady = false;
            } else if (phase === 11) {
                batteriesCheck(batteriesVisual().visual.devices[1].percentage === -1, "service loss hides stale charge");
                macBar.bluetooth.stateReady = true;
                macWidgets.visibilityConnected = true; macWidgets.overviewOpen = false;
                batteriesFrozen = JSON.stringify(model.entries);
                macWidgets.visibilityClients = [{output: batteriesOutput, geometryKnown: true, fullscreen: 1, workspaceActive: true, mapped: true, hidden: false}];
            } else if (phase === 12) {
                batteriesCheck(!model.active && state.sources.batteries === 0, "fullscreen stops normalization");
                macBar.battery.fraction = .2;
                macBar.bluetooth.devices = [batteriesDevice("AA:BB:CC:DD:EE:01", 97)];
            } else if (phase === 13) {
                batteriesCheck(JSON.stringify(model.entries) === batteriesFrozen, "inactive model freezes its snapshot");
                macWidgets.overviewOpen = true;
            } else if (phase === 14) {
                batteriesCheck(model.active && state.sources.batteries === 3, "overview restores sources");
                batteriesCheck(batteriesVisual().visual.devices[0].percentage === 20 && batteriesVisual().visual.devices[1].percentage === 97, "fresh data after resume");
                batteriesCheck(macWidgets.setWidgetsEnabled(false), "disable cards");
            } else if (phase === 15) {
                batteriesCheck(!model.active && state.sources.batteries === 0, "disable releases source");
                macWidgets.setEditorOpen("fixture", true);
            } else if (phase === 16) {
                batteriesCheck(model.active, "editor keeps device choices current with desktop disabled");
                batteriesToken = macWidgets.preferences.token;
                batteriesEditor.changeBatteries("devices", []);
                batteriesCheck(macWidgets.preferences.token === batteriesToken && batteriesEditor.dirty, "draft is write-free");
                batteriesEditor.load();
                batteriesCheck(!batteriesEditor.dirty && macWidgets.preferences.token === batteriesToken, "Cancel is write-free");
                batteriesEditor.changeBatteries("devices", ["laptop"]); batteriesEditor.apply();
            } else if (phase === 17) {
                batteriesCheck(!batteriesEditor.applying && !batteriesEditor.dirty && macWidgets.instanceRows[0].savedSettings.batteries.devices.join() === "laptop", "editor saves devices atomically");
                macWidgets.setEditorOpen("fixture", false); macWidgets.visibilityClients = []; macWidgets.overviewOpen = false;
                batteriesCheck(macWidgets.setWidgetsEnabled(true), "begin mount cycles");
                batteriesPhase = 20; return;
            } else if (phase === 20) {
                if (state.sources.batteries !== 3) return;
                batteriesCheck(model.active, "mounted model active");
                batteriesCheck(macWidgets.setWidgetsEnabled(false), "unmount");
                batteriesPhase = 21; return;
            } else if (phase === 21) {
                batteriesCheck(!model.active && state.sources.batteries === 0, "unmount releases source");
                if (++batteriesCycles < 20) { batteriesCheck(macWidgets.setWidgetsEnabled(true), "remount"); batteriesPhase = 20; return; }
                batteriesCheck(state.acquired - state.released === state.views && state.activeViews === 0, "all live consumer references balance");
                console.log("MACSHELL_BATTERIES_WIDGET_PASS: S/M/L, unknown/zero/full, duplicate identities and names, selected devices, Apply/Cancel/conflict, mirrors, disconnect/service loss/reconnect, fullscreen/overview and 20 mount cycles without discovery"); Qt.quit(); return;
            }
            batteriesPhase++;
        } catch (error) { console.error(error); Qt.exit(1); }
    }
}

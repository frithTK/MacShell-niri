import QtQuick
import "Locale" as Language
import Quickshell

Scope {
    id: root
    property bool active: true
    property bool available: false
    property bool enabled: false
    property bool pairingAvailable: false
    property var adapters: []
    property var devices: []
    property var others: []
    property var prompt: null
    property bool discovering: false
    property int batteryWatchers: 0
    property int connected: 0
    property bool loading: true
    property bool stateReady: false
    property string statusError: ""
    property string error: ""
    property string busyPath: ""
    property string busyAction: ""
    property bool busy: false
    property int request: -1
    readonly property bool refreshing: loading
    signal promptRequested()
    function refresh() { service.send("refresh"); }
    function run(kind, data) {
        if (busy) return;
        error = "";
        request = service.send(kind, data);
        if (request < 0) { error = "Bluetooth is unavailable."; return; }
        busy = true; busyAction = kind; busyPath = data.path || "";
    }
    function togglePower() { run("power", {enabled: !enabled}); }
    function discover() { error = ""; service.send(discovering ? "stopDiscovery" : "discover"); }
    function watchBatteries(on) {
        var next = Math.max(0, batteryWatchers + (on ? 1 : -1));
        if (next === batteryWatchers) return;
        batteryWatchers = next;
        if (on && batteryWatchers === 1) service.send("watchBatteries");
        else if (!on && batteryWatchers === 0) service.send("unwatchBatteries");
    }
    function pair(device) { if (device) run("pair", {path: device.path}); }
    function cancel() { service.send("cancel", {request: request}); }
    function respond(accept, value, promptId) { if (prompt && (promptId === undefined || prompt.id === promptId)) service.send("respond", {prompt: prompt.id, accept: accept, value: value || ""}); }
    function pick(device) {
        if (!device || !enabled || !device.adapterEnabled || device.blocked) return;
        run(device.connected ? "disconnect" : "connect", {path: device.path});
    }
    function deviceStatus(device) {
        if (busy && busyPath === device.path) return busyAction === "pair" ? "Pairing…" : busyAction === "connect" ? "Connecting…" : "Disconnecting…";
        if (device.blocked) return "Blocked";
        if (!device.adapterEnabled) return "Bluetooth adapter is off";
        return (device.connected ? "Connected" : "Not Connected") + (device.connected && device.battery >= 0 ? " · " + device.battery + "%" : "");
    }
    function deviceKind(device) {
        var icon = device.icon || "";
        if (/headset|headphone/.test(icon)) return "headphones";
        if (/audio/.test(icon)) return "speaker";
        if (/keyboard/.test(icon)) return "keyboard";
        if (/mouse/.test(icon)) return "mouse";
        return "bluetooth";
    }
    JsonService {
        id: service; script: "bluetooth_service.py"; launcher: "bluetooth-service.sh"; enabled: root.active
        onConnected: { root.refresh(); if (root.batteryWatchers > 0) service.send("watchBatteries"); }
        onReadyChanged: if (!ready) { root.stateReady = false; root.busy = false; root.request = -1; root.prompt = null; root.statusError = error; }
        onReceived: m => {
            if (m.type === "state") {
                root.stateReady = true;
                root.loading = false; root.statusError = ""; root.available = !!m.available; root.enabled = !!m.enabled;
                root.adapters = m.adapters || []; root.connected = m.connected || 0; root.discovering = !!m.discovering; root.pairingAvailable = !!m.pairingAvailable;
                if (JSON.stringify(root.devices) !== JSON.stringify(m.devices)) root.devices = m.devices || [];
                var nextOthers = root.discovering ? (m.others || []) : [];
                if (JSON.stringify(root.others) !== JSON.stringify(nextOthers)) root.others = nextOthers;
            } else if (m.type === "result" && m.id === root.request) {
                root.busy = false; root.busyPath = ""; root.busyAction = ""; root.request = -1; root.error = m.error || "";
            } else if (m.type === "prompt") { root.prompt = m.prompt; if (root.prompt) root.promptRequested(); }
            else if (m.type === "error") { if (m.id === undefined) root.stateReady = false; root.error = m.error || Language.I18n.text("ui.t_e23e473ce43c"); if (m.id === root.request) { root.busy = false; root.busyPath = ""; root.request = -1; } }
            else if (m.type === "unavailable") { root.stateReady = false; root.loading = false; root.available = false; root.enabled = false; root.devices = []; root.others = []; root.error = m.error; }
        }
    }
}

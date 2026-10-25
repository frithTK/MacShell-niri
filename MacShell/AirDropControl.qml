import QtQuick
import Quickshell

Scope {
    id: root
    property bool enabled: false
    property bool airplayBusy: false
    property string receiverName: "MacShell"
    property string error: ""
    property bool probeRequested: false
    property var state: ({available: false, configured: false, canStart: false, mode: "", status: "off", notice: "", files: [], devices: [], pending: null, receiving: false, scanning: false, transfer: "idle", progress: {sent: 0, total: 0}, results: [], folder: ""})
    readonly property bool active: ["starting", "ready", "stopping"].indexOf(state.status) >= 0
    readonly property bool transferring: ["waiting", "sending", "receiving"].indexOf(state.transfer) >= 0
    readonly property string label: state.status === "starting" ? "Starting…" : state.status === "stopping" ? "Stopping…" : state.pending ? "Incoming files" : transferring ? "Transferring" : active ? "Everyone · 10 min" : state.mode && state.mode !== "shared" ? "Unavailable" : "Off"
    signal showRequested()
    function send(action, data) { error = ""; service.send(action, data); }
    function refresh() { probeRequested = !active; send(active ? "scan" : "probe"); }
    function start() {
        if (airplayBusy) { error = "Stop AirPlay before enabling AirDrop."; return; }
        if (!state.canStart) { error = "AirDrop would disconnect Wi-Fi on this adapter. This mode is disabled."; return; }
        send("start", {name: receiverName});
    }
    function stop() { send("stop"); }
    function setFiles(paths) { send("files", {paths: paths}); }
    function sendFiles(key) { send("send", {key: key}); }
    function answer(key, accept) { send("answer", {key: key, accept: accept}); }
    function cancel() { send("cancel"); }
    onAirplayBusyChanged: service.send("blocked", {enabled: airplayBusy})
    JsonService {
        id: service; script: "airdrop_service.py"; enabled: root.enabled
        onConnected: { service.send("blocked", {enabled: root.airplayBusy}); if (root.probeRequested) service.send("probe"); }
        onReadyChanged: if (!ready) {
            root.state = Object.assign({}, root.state, {status: "off", pending: null, receiving: false, scanning: false, transfer: "idle"});
            root.error = error;
        }
        onReceived: message => {
            if (message.type === "error") { root.error = message.error || "AirDrop operation failed."; return; }
            if (message.type !== "state") return;
            var previous = root.state.pending;
            root.state = message; root.error = message.error || "";
            if (message.pending && (!previous || previous.key !== message.pending.key)) root.showRequested();
        }
    }
}

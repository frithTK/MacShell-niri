import QtQuick
import "Locale" as Language
import Quickshell

Scope {
    id: root
    property bool active: true
    property bool enabled: false
    property bool available: false
    property bool ethernet: false
    property var networks: []
    property string error: ""
    property string busy: ""
    property int request: -1
    property var selected: null
    property var prompt: null
    property bool secretNeeded: false
    property bool scanning: false
    readonly property string ssid: { var n = networks.find(n => n.inUse); return n ? n.ssid : ""; }
    readonly property int strength: { var n = networks.find(n => n.inUse); return n ? n.signal : 0; }
    signal promptRequested()
    function refresh() { service.send("refresh"); }
    function scan() { scanning = true; service.send("scan"); scanTimer.restart(); }
    function power(value) { service.send("power", {enabled: value}); }
    function pick(network) {
        if (!network || busy !== "") return;
        error = "";
        if (network.inUse) { service.send("disconnect", {network: network.id}); return; }
        selected = network;
        if (!network.supported) { error = "This network needs advanced network settings."; return; }
        if (network.secure && !network.saved) { prompt = network; secretNeeded = false; promptRequested(); }
        else join(network, "");
    }
    function join(network, password) {
        error = "";
        if (!secretNeeded && network.security === "wpa-psk" && !network.saved && !(password.length >= 8 && password.length <= 63 || /^[0-9a-fA-F]{64}$/.test(password))) {
            error = "WPA password must contain 8–63 characters."; return;
        }
        if (secretNeeded) service.send("secret", {request: request, password: password});
        else {
            selected = network;
            request = service.send("join", {network: network.id, password: password});
            if (request < 0) { error = "NetworkManager is unavailable."; return; }
            busy = network.id;
        }
        prompt = null;
        secretNeeded = false;
    }
    function retryPrompt() {
        if (!selected || !selected.secure) return;
        prompt = networks.find(n => n.id === selected.id) || selected;
        secretNeeded = false;
        promptRequested();
    }
    function cancel() {
        if (request >= 0) service.send("cancel", {request: request});
        prompt = null;
        secretNeeded = false;
    }
    JsonService {
        id: service; script: "network_control.py"; enabled: root.active
        onConnected: root.refresh()
        onReadyChanged: if (!ready) { root.request = -1; root.busy = ""; root.prompt = null; root.error = error; }
        onReceived: m => {
            if (m.type === "state") {
                root.available = !!m.available; root.enabled = !!m.enabled; root.ethernet = !!m.ethernet;
                if (JSON.stringify(root.networks) !== JSON.stringify(m.networks)) root.networks = m.networks || [];
            } else if (m.type === "secret" && m.id === root.request) {
                root.prompt = m.network; root.secretNeeded = true; root.error = m.error || ""; root.promptRequested();
            } else if (m.type === "result" && m.id === root.request) {
                root.busy = ""; root.request = -1; root.prompt = null; root.error = m.error || ""; root.refresh(); if (root.error !== "") root.retryPrompt();
            } else if (m.type === "error") { root.error = m.error || Language.I18n.text("ui.t_4f6393e297f7"); if (m.id === root.request) { root.busy = ""; root.request = -1; root.retryPrompt(); } }
            else if (m.type === "unavailable") { root.available = false; root.enabled = false; root.networks = []; root.error = m.error; }
        }
    }
    Timer { id: scanTimer; interval: 4000; onTriggered: root.scanning = false }
}

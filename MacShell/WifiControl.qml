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
    property var links: []
    property var proxy: null
    property var hotspot: null
    property var vpn: null
    property bool vpnPrompt: false
    signal vpnChallenge()
    property int linkRequest: -1
    property int vpnDelivery: -1
    property string fault: ""
    signal settled(string scope, bool ok)
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
        fault = "";
        if (network.inUse) { service.send("disconnect", {network: network.id}); return; }
        selected = network;
        if (!network.supported) { error = "This network needs advanced network settings."; return; }
        if (network.secure && !network.saved) { prompt = network; secretNeeded = false; promptRequested(); }
        else join(network, "");
    }
    function join(network, password) {
        error = "";
        fault = "";
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
        vpnPrompt = false;
    }
    function track(id) {
        linkRequest = id;
        if (id < 0) error = explain("NetworkManager is unavailable.");
        else busy = "network";
    }
    function begin(scope) {
        error = "";
        fault = scope;
        vpnPrompt = false;
    }
    function linkToggle(link) {
        if (!link || !link.controllable || busy !== "") return;
        begin("vpn");
        track(service.send("link", {uuid: link.uuid, path: link.path, up: !link.active}));
    }
    function linkDelete(link) {
        if (!link || !link.removable || busy !== "") return;
        begin("vpn");
        track(service.send("delete", {uuid: link.uuid, path: link.path}));
    }
    function importProfile(path) {
        if (!path || busy !== "") return;
        begin("vpn");
        track(service.send("import", {path: path}));
    }
    function saveProxy(form) {
        if (!form || !proxy || busy !== "") return;
        begin("proxy");
        track(service.send("proxy", form));
    }
    function startHotspot(ssid, password, restore) {
        if (busy !== "") return;
        begin("hotspot");
        track(service.send("hotspot", {enabled: true, ssid: ssid, password: password, restore: restore || ""}));
    }
    function stopHotspot() {
        if (busy !== "") return;
        begin("hotspot");
        track(service.send("hotspot", {enabled: false}));
    }
    function toggleVpn(enabled) {
        if (busy !== "") return;
        if (enabled && (!vpn || !vpn.available)) return;
        begin("vpn");
        track(service.send("vpn", {enabled: !!enabled}));
    }
    function submitVpn(password) {
        error = "";
        fault = "vpn";
        service.send("secret", {request: linkRequest, delivery: vpnDelivery, password: password, vpn: true});
        vpnPrompt = false;
    }
    function cancelVpn() {
        if (!vpnPrompt) return;
        service.send("cancel", {vpn: true, request: linkRequest});
        vpnPrompt = false;
    }
    function explain(text) {
        var key = ({
            "Wi-Fi operation already in progress": "network.busy",
            "The VPN profile needs a password.": "network.vpn_needs_password",
            "This VPN type is not available.": "network.vpn_type",
            "The file is not a readable profile.": "network.import_bad",
            "This connection cannot be changed from here.": "network.locked",
            "The network route changed. Reload and try again.": "network.route_changed",
            "Enter at least one proxy address.": "network.proxy_required",
            "Enter a proxy as host:port.": "network.proxy_format",
            "The PAC address must be an http or https URL.": "network.proxy_pac_bad",
            "The proxy bypass list is invalid.": "network.proxy_bypass_bad",
            "Unknown proxy mode.": "network.proxy_format",
            "The hotspot name must be 1–32 bytes.": "network.hotspot_name_bad",
            "The hotspot password must contain 8–63 characters.": "network.hotspot_password_bad",
            "Hotspot needs a Wi-Fi device that can start an access point.": "network.hotspot_unavailable",
            "The current Wi-Fi channel does not allow an access point.": "network.hotspot_channel",
            "The access-point interface was not authorized.": "network.hotspot_auth",
            "A connection named MacShell Hotspot already exists.": "network.hotspot_name_taken",
            "Wi-Fi is sharing a network.": "network.hotspot_sharing",
            "NetworkManager rejected the change.": "network.failed",
            "Wi-Fi operation failed.": "network.failed",
            "Enter the VPN password.": "network.vpn_needs_password",
            "There is no saved VPN to turn on.": "network.vpn_none"
        })[text];
        return key ? Language.I18n.text(key) : (text || "");
    }
    JsonService {
        id: service; script: "network_control.py"; launcher: "network-service.sh"; enabled: root.active
        onConnected: root.refresh()
        onReadyChanged: if (!ready) { root.request = -1; root.busy = ""; root.prompt = null; root.error = error; }
        onReceived: m => {
            if (m.type === "state") {
                root.available = !!m.available; root.enabled = !!m.enabled; root.ethernet = !!m.ethernet;
                if (JSON.stringify(root.networks) !== JSON.stringify(m.networks)) root.networks = m.networks || [];
                root.links = m.links || [];
                root.proxy = m.proxy || null;
                root.hotspot = m.hotspot || null;
                root.vpn = m.vpn || null;
            } else if (m.type === "secret" && m.vpn) {
                root.linkRequest = m.id; root.vpnDelivery = m.delivery; root.vpnPrompt = true; root.fault = "vpn"; root.error = "";
                root.vpnChallenge();
            } else if (m.type === "secret" && m.id === root.request) {
                root.prompt = m.network; root.secretNeeded = true; root.error = m.error || ""; root.promptRequested();
            } else if (m.type === "result" && m.id === root.linkRequest) {
                var scope = root.fault;
                root.busy = ""; root.linkRequest = -1; root.fault = ""; root.error = ""; root.vpnPrompt = false;
                root.settled(scope, true); root.refresh();
            } else if (m.type === "result" && m.id === root.request) {
                root.busy = ""; root.request = -1; root.prompt = null; root.error = m.error || ""; root.refresh(); if (root.error !== "") root.retryPrompt();
            } else if (m.type === "error") {
                root.error = root.explain(m.error || Language.I18n.text("ui.t_4f6393e297f7"));
                if (m.id === root.request) { root.busy = ""; root.request = -1; root.retryPrompt(); }
                if (m.id === root.linkRequest) { root.busy = ""; root.linkRequest = -1; root.vpnPrompt = false; root.settled(root.fault, false); }
            }
            else if (m.type === "unavailable") { root.available = false; root.enabled = false; root.networks = []; root.vpn = null; root.error = m.error; }
        }
    }
    Timer { id: scanTimer; interval: 4000; onTriggered: root.scanning = false }
}

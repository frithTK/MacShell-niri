import QtQuick
import Quickshell

Scope {
    id: root
    property bool gaming: false
    property bool available: false
    property bool busy: false
    property string profile: ""
    property var profiles: []
    property string inhibited: ""
    property string degraded: ""
    property string error: ""
    property bool gameHold: false
    function label(value) {
        return ({"power-saver": "Low Power", balanced: "Balanced", performance: "Performance"})[value] || value || "Unavailable";
    }
    function supported(value) { return available && profiles.indexOf(value) >= 0 && (value !== "performance" || inhibited === ""); }
    function select(value) { if (!busy && supported(value)) { error = ""; busy = true; service.send("select", {profile: value}); } }
    function refresh() { service.send("refresh"); }
    onGamingChanged: service.send("game", {enabled: gaming})
    JsonService {
        id: service; script: "power_control.py"
        onConnected: { root.refresh(); send("game", {enabled: root.gaming}); }
        onReceived: m => {
            if (m.type === "state") {
                root.available = m.available; root.busy = m.busy; root.profile = m.profile;
                root.profiles = m.profiles; root.inhibited = m.inhibited; root.degraded = m.degraded;
                root.gameHold = m.gameHold; root.error = m.error || "";
            } else if (m.type === "unavailable") {
                root.available = false; root.busy = false; root.profile = ""; root.profiles = [];
                root.gameHold = false; root.error = m.error || "Power profiles service unavailable.";
            } else if (m.type === "error") { root.busy = false; root.error = m.error; }
        }
        onReadyChanged: if (!ready) { root.available = false; root.busy = false; root.gameHold = false; }
    }
}

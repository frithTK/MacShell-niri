import QtQuick
import Quickshell

Scope {
    id: root
    property bool active: false
    property bool desired: false
    property int temperature: 4000
    property int appliedTemperature: 0
    property bool available: false
    property string state: "off"
    property string error: ""
    readonly property bool enabled: state === "on"
    readonly property string label: !available ? "Requires wlsunset" : state === "starting" ? "Applying…" : state === "error" ? "Unable to apply" : enabled ? appliedTemperature + " K" : "Off"
    function configure() { service.send("configure", {enabled: desired, temperature: temperature}); }
    function retry() { debounce.stop(); configure(); }
    onDesiredChanged: { debounce.stop(); configure(); }
    onTemperatureChanged: debounce.restart()
    JsonService {
        id: service; script: "night_shift.py"; enabled: root.active
        onConnected: root.configure()
        onReceived: m => { if (m.type === "state") { root.available = m.available; root.state = m.state; root.error = m.error || ""; root.appliedTemperature = m.appliedTemperature || 0; } }
        onReadyChanged: if (!ready) { root.state = "off"; root.error = error; }
    }
    Timer { id: debounce; interval: 250; onTriggered: root.configure() }
}

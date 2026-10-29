import QtQuick
import "Locale" as Language
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
    readonly property string label: !available ? Language.I18n.text("ui.t_4070e998d386") : state === "starting" ? Language.I18n.text("ui.t_3329a9bb48b9") : state === "error" ? Language.I18n.text("ui.t_751dd3a51496") : enabled ? appliedTemperature + " K" : Language.I18n.text("ui.t_ca7981b46ecf")
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

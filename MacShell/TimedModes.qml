import QtQuick
import "Locale" as Language
import Quickshell

Scope {
    id: root
    property bool enabled: false
    property var saved: ({focus: {mode: "off"}, awake: {mode: "off"}})
    property var values: ({})
    property var remaining: ({})
    property bool restored: false
    property string error: ""
    signal persist(var value)
    function active(kind) { return restored && values[kind] && values[kind].mode !== "off"; }
    function set(kind, mode) { service.send("set", {kind: kind, mode: mode}); }
    function toggle(kind) { set(kind, active(kind) ? "off" : "manual"); }
    function label(kind) {
        if (!active(kind)) return Language.I18n.text("ui.t_ca7981b46ecf");
        var v = values[kind], left = remaining[kind];
        if (v.mode === "manual") return Language.I18n.text("ui.t_53e7119012bc");
        if (v.mode === "evening") return Language.I18n.text("ui.t_3e84e4d04f57") + new Date(v.utc * 1000).toLocaleString(Language.I18n.formatLocale, "ddd HH:mm");
        return Math.ceil((left || 0) / 60) + " min remaining";
    }
    JsonService {
        id: service; script: "timed_modes.py"; launcher: "timed-modes.sh"; enabled: root.enabled
        onConnected: service.send("restore", root.saved)
        onReadyChanged: if (!ready) root.restored = false
        onReceived: m => {
            if (m.type !== "state") return;
            root.restored = true; root.values = m.values || {}; root.remaining = m.remaining || {};
            if (m.changed) { root.saved = root.values; root.persist(root.values); }
        }
    }
}

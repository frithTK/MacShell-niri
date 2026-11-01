import QtQuick
import "Locale" as Language
import Quickshell
import "WidgetLayout.js" as Layout

Scope {
    id: root
    property bool enabled: true
    property var origin: ({})
    property bool ready: false
    property bool pending: false
    property bool loading: false
    property bool readOnly: true
    property bool canRecover: false
    property bool awaitingDisplay: false
    property var values: ({defaults: {tempUnit: "C", locMode: "auto", cityName: "", styles: {weather: "liquid", calendar: "liquid", clock: "liquid", player: "liquid", activity: "liquid", batteries: "liquid", timer: "liquid"}, mode: "auto"}, desktopOutput: "", outputs: {}, bindings: {}, widgets: []})
    property string token: ""
    property string notice: ""
    property string error: ""
    property int request: -1
    property string sentOrigin: ""
    property bool resetWeatherRequested: false
    readonly property bool editable: ready && !pending && !loading && !readOnly
    signal changed()
    signal finished(bool success)
    onOriginChanged: Qt.callLater(refreshForOrigin)
    function refreshForOrigin() { if (JSON.stringify(origin) !== sentOrigin) refresh(); }
    function refresh() {
        if (pending || loading || !service.ready) return;
        error = ""; sentOrigin = JSON.stringify(origin); loading = true;
        service.send("load", {origin: origin});
    }
    function save(next) {
        if (!editable) return false;
        return send("commit", {values: next, token: token});
    }
    function recover() { if (ready && !pending && !loading && canRecover) return send("recover", {token: token}); return false; }
    function send(action, data) {
        error = ""; request = service.send(action, data); pending = request >= 0;
        if (!pending) { error = "Widget settings are unavailable."; finished(false); }
        return pending;
    }
    function resetWeather() {
        resetWeatherRequested = true;
        if (!ready || pending || loading) return;
        resetWeatherRequested = false;
        if (readOnly) { error = notice; finished(false); return; }
        var next = Layout.clone(values);
        next.defaults.tempUnit = "C"; next.defaults.locMode = "auto"; next.defaults.cityName = "";
        save(next);
    }
    JsonService {
        id: service
        script: "widget_layout_service.py"; enabled: root.enabled
        onConnected: root.refresh()
        onErrorChanged: if (error) root.error = error
        onReadyChanged: if (!ready) {
            root.ready = false; root.loading = false;
            if (root.pending) { root.pending = false; root.error = "Widget settings disconnected. Reload before editing."; root.finished(false); }
        }
        onReceived: m => {
            if (m.type === "state") {
                root.values = m.values; root.token = m.token; root.readOnly = m.readOnly; root.canRecover = m.canRecover;
                root.awaitingDisplay = !!m.awaitingDisplay; root.notice = m.notice; root.loading = false; root.ready = true; root.changed();
                if (!root.pending && JSON.stringify(root.origin) !== root.sentOrigin) Qt.callLater(root.refresh);
                else if (root.resetWeatherRequested && !root.pending) Qt.callLater(root.resetWeather);
            } else if (m.type === "result" && m.id === root.request) {
                root.pending = false; root.error = m.error || ""; root.finished(!!m.success);
                if (root.resetWeatherRequested) Qt.callLater(root.resetWeather);
                else if (JSON.stringify(root.origin) !== root.sentOrigin) Qt.callLater(root.refresh);
            } else if ((m.type === "result" && root.loading && !m.success) || m.type === "error") {
                root.loading = false; root.pending = false; root.error = m.error || Language.I18n.text("ui.t_b5e38626b85d"); root.finished(false);
            }
        }
    }
}

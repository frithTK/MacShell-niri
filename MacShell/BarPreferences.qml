import QtQuick
import Quickshell
import "BarLayout.js" as Layout
import "OutputProfiles.js" as Outputs

Scope {
    id: root
    property bool enabled: true
    property var legacy: ({})
    property var outputs: []
    property real widgetScale: 1
    property bool ready: false
    property bool pending: false
    property bool readOnly: true
    property bool canRecover: false
    property bool needsRepair: false
    property bool migrationPending: false
    property var values: ({common: [], outputs: {}, bindings: {}})
    property var catalog: []
    property string token: ""
    property string notice: ""
    property string error: ""
    property int request: -1
    property bool resetRequested: false
    signal finished(bool success)
    function refresh() { if (!pending && service.ready) { error = ""; service.send("load", {legacy: legacy}); } }
    function layoutFor(output) { return Outputs.effective(values, output, outputs); }
    function commonEnabled(type) { return values.common.some(item => item.type === type && item.enabled); }
    function setEnabled(type, enabled) {
        if (!ready || pending || readOnly) return;
        var next = Layout.clone(values), block = next.common.find(item => item.type === type);
        if (block) block.enabled = enabled;
        else {
            var definition = catalog.find(item => item.type === type);
            if (!definition) return;
            next.common.push({id: type, type: type, zone: definition.zone, enabled: enabled, priority: definition.priority});
        }
        save(next, token);
    }
    function resetToDefaults() {
        resetRequested = true;
        if (!ready || pending) return;
        resetRequested = false;
        if (canRecover) recover(token);
        else if (!readOnly) save({common: Layout.defaults(catalog), outputs: {}, bindings: {}}, token);
        else { error = notice; finished(false); }
    }
    onReadyChanged: if (ready && resetRequested && !pending) Qt.callLater(resetToDefaults)
    function save(values, baseToken) { if (ready && !pending && !readOnly) send("commit", {values: values, token: baseToken}); }
    function recover(baseToken) { if (ready && !pending && canRecover) send("recover", {token: baseToken}); }
    function send(action, data) {
        error = ""; request = service.send(action, data); pending = request >= 0;
        if (!pending) { error = "Menu bar settings are unavailable."; finished(false); }
    }
    JsonService {
        id: service
        script: "bar_layout_service.py"; launcher: "bar-preferences.sh"; enabled: root.enabled
        onConnected: root.refresh()
        onErrorChanged: if (error) root.error = error
        onReadyChanged: if (!ready) {
            root.ready = false;
            if (root.pending) { root.pending = false; root.error = "Menu bar settings disconnected. Reload before applying."; root.finished(false); }
        }
        onReceived: m => {
            if (m.type === "state") {
                root.catalog = m.catalog; root.values = m.values; root.token = m.token;
                root.readOnly = m.readOnly; root.canRecover = m.canRecover;
                root.needsRepair = m.needsRepair; root.migrationPending = m.migrationPending;
                root.notice = m.notice; root.ready = true;
            } else if (m.type === "result" && m.id === root.request) {
                root.pending = false; root.error = m.error || ""; root.finished(!!m.success);
                if (root.resetRequested) Qt.callLater(root.resetToDefaults);
            } else if (m.type === "error") { root.pending = false; root.error = m.error; root.finished(false); }
        }
    }
}

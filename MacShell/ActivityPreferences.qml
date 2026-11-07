import QtQuick
import "Locale" as Language
import Quickshell
import "PreferenceFields.js" as Fields

Scope {
    id: root
    property bool enabled: true
    property bool ready: false
    property bool pending: false
    property bool readOnly: true
    property bool canRecover: false
    property bool needsRepair: false
    property bool migrationPending: false
    property var values: ({})
    property var fields: []
    property string token: ""
    property int revision: 0
    property string notice: ""
    property string error: ""
    property int request: -1
    property bool resetRequested: false
    signal finished(bool success)
    onReadyChanged: if (ready && resetRequested && !pending) Qt.callLater(resetToDefaults)
    function resetToDefaults() {
        resetRequested = true;
        if (!ready || pending) return;
        resetRequested = false;
        if (canRecover) recover(token);
        else if (!readOnly) save(Fields.defaults(fields), token);
        else { error = notice; finished(false); }
    }
    function refresh() { if (!pending) service.send("load"); }
    function save(values, baseToken) {
        if (!ready || pending || readOnly) return;
        send("commit", {values: values, token: baseToken});
    }
    function recover(baseToken) {
        if (!ready || pending || !canRecover) return;
        send("recover", {token: baseToken});
    }
    function send(action, data) {
        error = "";
        request = service.send(action, data);
        pending = request >= 0;
        if (!pending) { error = "Activity settings are unavailable."; finished(false); }
    }
    JsonService {
        id: service
        script: "activity_preferences_service.py"
        launcher: "activity-preferences.sh"
        enabled: root.enabled
        onConnected: root.refresh()
        onReadyChanged: if (!ready) {
            root.ready = false;
            if (root.pending) { root.pending = false; root.error = "Activity settings disconnected. Reload before applying."; root.finished(false); }
        }
        onReceived: m => {
            if (m.type === "state") {
                root.fields = m.fields;
                root.values = m.values;
                root.token = m.token;
                root.revision = m.revision;
                root.readOnly = m.readOnly;
                root.canRecover = m.canRecover;
                root.needsRepair = m.needsRepair;
                root.migrationPending = m.migrationPending;
                root.notice = m.notice;
                root.ready = true;
            } else if (m.type === "result" && m.id === root.request) {
                root.pending = false;
                root.error = m.error || "";
                root.finished(!!m.success);
                if (root.resetRequested) Qt.callLater(root.resetToDefaults);
            } else if (m.type === "error") {
                root.pending = false;
                root.error = m.error || Language.I18n.text("ui.t_d3062064c1c6");
                root.finished(false);
            }
        }
    }
}

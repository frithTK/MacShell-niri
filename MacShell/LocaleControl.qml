import QtQuick
import Quickshell
import "Locale" as Language

Scope {
    id: root
    property bool enabled: true
    property bool ready: false
    property bool pending: false
    property var values: ({ui: "system", session: "system", region: "system"})
    property var locales: []
    property var current: ({})
    property var missing: []
    property string token: ""
    property string conflict: ""
    property string errorCode: ""
    property string errorDetail: ""
    property bool nextLogin: false
    property int request: -1
    signal finished(bool success)
    function refresh() {
        if (!service.ready || pending) return;
        errorCode = ""; pending = true; request = service.send("load", {});
    }
    function save(draft, expectedToken) {
        if (!ready || pending || !service.ready) return false;
        errorCode = ""; pending = true; request = service.send("save", {values: draft, token: expectedToken});
        return request >= 0;
    }
    JsonService {
        id: service
        script: "locale_service.py"; launcher: "locale-preferences.sh"
        enabled: root.enabled
        onConnected: root.refresh()
        onReadyChanged: if (!ready) { root.ready = false; root.pending = false; }
        onReceived: message => {
            if (message.type === "state") {
                root.values = message.values; root.token = message.token; root.locales = message.locales;
                root.current = message.current; root.conflict = message.conflict; root.nextLogin = message.pending;
                root.missing = message.missing || []; root.ready = true;
                Language.I18n.language = message.values.ui;
                Language.I18n.region = message.values.region;
            } else if (message.type === "result" && message.id === root.request) {
                root.pending = false; root.errorCode = message.code || ""; root.errorDetail = message.detail || "";
                root.finished(!!message.success);
            }
        }
    }
}

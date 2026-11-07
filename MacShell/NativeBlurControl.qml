import QtQuick
import Quickshell

Scope {
    id: root
    property real level: 5
    property bool active: false
    property bool available: false
    property bool managed: false
    property int appliedLevel: -1
    property string error: ""
    property bool pending: false
    function apply() { pending = true; debounce.restart(); }
    onLevelChanged: if (managed) apply()
    JsonService {
        id: service
        script: "native_blur.py"; launcher: "native-blur.sh"
        enabled: root.active
        onConnected: {
            service.send("inspect");
            if (root.pending) debounce.restart();
        }
        onReceived: m => {
            if (m.type !== "state") return;
            root.available = m.available;
            root.managed = m.managed;
            root.appliedLevel = m.level;
            root.error = m.error || "";
            if (root.managed && root.appliedLevel !== Math.round(root.level)) root.apply();
        }
        onReadyChanged: if (!ready) { root.available = false; root.error = error; }
    }
    Timer {
        id: debounce
        interval: 180
        onTriggered: {
            if (service.ready) {
                root.pending = false;
                service.send("apply", {level: root.level});
            }
        }
    }
}

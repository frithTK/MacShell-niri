import QtQuick
import Quickshell
import Quickshell.Io

// One JSON-lines process per service, shared by every screen. A restarted process
// cannot complete an old request: both generation and request ID travel on the wire.
Scope {
    id: root
    property string script: ""
    property var arguments: []
    property bool enabled: true
    property bool ready: false
    property string error: ""
    property int generation: 0
    property int sequence: 0
    property int failures: 0
    readonly property string helper: decodeURIComponent(Qt.resolvedUrl(script).toString().replace(/^file:\/\//, ""))
    signal received(var message)
    signal connected()
    function send(action, data) {
        if (!ready) return -1;
        var id = ++sequence;
        process.write(JSON.stringify({action: action, data: data || {}, id: id, generation: generation}) + "\n");
        return id;
    }
    function start() {
        if (!enabled || process.running) return;
        generation++;
        process.command = ["python3", "-u", helper].concat(root.arguments);
        process.running = true;
    }
    onEnabledChanged: {
        restart.stop();
        if (enabled) start(); else { ready = false; process.running = false; }
    }
    Component.onCompleted: if (enabled) start()
    Process {
        id: process
        stdinEnabled: true
        stdout: SplitParser {
            onRead: line => {
                try {
                    var m = JSON.parse(line);
                    if (m.generation !== undefined && m.generation !== root.generation) return;
                    if (!root.ready && m.type !== "unavailable" && m.type !== "error") { root.ready = true; root.failures = 0; root.error = ""; root.connected(); }
                    root.received(m);
                } catch (e) { root.error = "Invalid service response"; }
            }
        }
        onExited: (code, status) => {
            if (root.enabled) {
                root.error = "Service disconnected; retrying…";
                root.ready = false;
                root.failures = Math.min(root.failures + 1, 6);
                restart.restart();
            } else root.ready = false;
        }
    }
    Timer { id: restart; interval: Math.min(30000, 500 * Math.pow(2, root.failures)); onTriggered: root.start() }
}

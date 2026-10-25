pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Scope {
    id: root
    property var frames: ({})
    property var requested: ({})
    property bool available: true
    property bool enabled: true
    onEnabledChanged: if (!enabled) { frames = {}; requested = {}; }
    function acceptFrame(frame) {
        if (frame.error) {
            var remaining = Object.assign({}, frames);
            delete remaining[String(frame.id)]; frames = remaining;
            if (frame.fatal || frame.id === undefined || Niri.windowMap[String(frame.id)])
                console.warn("[capture] " + frame.error);
            if (frame.fatal) available = false;
        } else if (enabled && Niri.windowMap[String(frame.id)]) {
            var next = Object.assign({}, frames); next[String(frame.id)] = frame; frames = next;
        }
    }
    readonly property int frameInterval: Math.round(1000 / Math.max(1, Math.min(10, parseInt(Quickshell.env("MACSHELL_CAPTURE_FPS")) || 5)))
    function request(source) {
        if (!enabled || !available || !source || !source.id || !worker.running) return;
        var key = String(source.id), now = Date.now();
        if (now - (requested[key] || 0) < frameInterval) return;
        requested[key] = now;
        worker.write(JSON.stringify({ id: source.id }) + "\n");
    }
    Connections {
        target: Niri
        function onUpdated() {
            var next = {}, times = {}, framesRemoved = false, requestsRemoved = false;
            for (var key in root.frames) { if (Niri.windowMap[key]) next[key] = root.frames[key]; else framesRemoved = true; }
            for (var id in root.requested) { if (Niri.windowMap[id]) times[id] = root.requested[id]; else requestsRemoved = true; }
            if (framesRemoved) root.frames = next;
            if (requestsRemoved) root.requested = times;
        }
    }
    Process {
        id: worker
        command: ["python3", "-u", Qt.resolvedUrl("niri_capture.py").toString().replace(/^file:\/\//, "")]
        running: root.enabled
        stdinEnabled: true
        stdout: SplitParser {
            onRead: line => {
                try {
                    var frame = JSON.parse(line);
                    root.acceptFrame(frame);
                } catch (e) { console.warn("[capture] " + e); }
            }
        }
        onExited: {
            root.frames = {}; root.requested = {};
            if (root.enabled && root.available) retry.restart();
        }
    }
    Timer { id: retry; interval: 5000; onTriggered: worker.running = true }
}

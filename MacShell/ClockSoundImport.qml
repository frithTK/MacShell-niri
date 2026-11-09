import QtQuick
import Quickshell
import Quickshell.Io

Scope {
    id: root
    required property string directory
    property var queue: []
    property bool busy: process.running || queue.length > 0
    property string error: ""
    property bool workerSuccess: false
    property bool workerReported: false
    property bool cancelling: false
    property bool cancelled: false
    property int importedCount: 0
    property int duplicateCount: 0
    property int failedCount: 0
    property bool aacSupported: false
    property bool codecsProbed: false
    readonly property string helper: decodeURIComponent(Qt.resolvedUrl("clock-sound-import.sh").toString().replace(/^file:\/\//, ""))
    signal finished()

    function probeCodecs() {
        if (codecsProbed || codecProbe.running) return;
        aacSupported = false; codecProbe.command = ["ffmpeg", "-hide_banner", "-decoders"]; codecProbe.running = true;
    }

    function importFiles(urls) {
        if (busy) return;
        var paths = [];
        for (var url of urls) {
            var value = String(url);
            if (!value.startsWith("file:///")) { error = "Invalid local file"; return; }
            try { paths.push(decodeURIComponent(value.slice(7))); }
            catch (e) { error = "Invalid local file"; return; }
        }
        if (!paths.length || paths.length > 50) { error = "Too many files"; return; }
        error = ""; cancelling = false; cancelled = false; importedCount = 0; duplicateCount = 0; failedCount = 0; queue = paths; next();
    }
    function cancel() {
        if (!busy) return;
        cancelling = true; cancelled = true; queue = []; error = "";
        if (process.running && process.processId > 0) process.signal(15);
        else if (!process.running) { cancelling = false; finished(); }
    }
    function next() {
        if (process.running) return;
        if (!queue.length) { finished(); return; }
        var paths = queue.slice(), path = paths.shift(); queue = paths;
        workerSuccess = false; workerReported = false;
        process.command = ["sh", helper, "--library", directory, path];
        process.running = true;
    }
    Process {
        id: process
        onStarted: if (root.cancelling) process.signal(15)
        stdout: SplitParser {
            onRead: line => {
                try {
                    var result = JSON.parse(line); root.workerReported = true; root.workerSuccess = result.success === true;
                    if (!root.workerSuccess) { root.failedCount++; root.error = result.error || "Import failed"; }
                    else if (result.created) root.importedCount++; else root.duplicateCount++;
                }
                catch (e) { root.error = "Import failed"; }
            }
        }
        onExited: (code, status) => {
            if (root.cancelling) { root.cancelling = false; root.queue = []; root.finished(); return; }
            if (code !== 0 || !root.workerSuccess) { if (!root.workerReported) root.failedCount++; root.error = root.error || "Import failed"; }
            Qt.callLater(root.next);
        }
    }
    Process {
        id: codecProbe
        onStarted: codecTimeout.restart()
        stdout: SplitParser { onRead: line => { if (/^\s*A\S*\s+aac\s/.test(line)) root.aacSupported = true; } }
        onExited: (code, status) => { codecTimeout.stop(); if (code !== 0) root.aacSupported = false; root.codecsProbed = true; }
    }
    Timer { id: codecTimeout; interval: 5000; onTriggered: { codecProbe.running = false; root.aacSupported = false; root.codecsProbed = true; } }
}

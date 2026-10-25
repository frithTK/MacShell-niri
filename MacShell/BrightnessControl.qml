import QtQuick
import Quickshell
import Quickshell.Io
import "BrightnessValue.js" as BrightnessValue

Scope {
    id: root
    property bool active: true
    property real value: 0.5
    property bool available: false
    // Discovery retains brightnessctl's device selection. Subsequent reads use
    // the same device directly, with no recurring shell/brightnessctl process.
    property string sysfsRoot: "/sys/class"
    property var discoveryCommand: ["brightnessctl", "-m"]
    property string devicePath: ""
    property real current: NaN
    property real maximum: NaN
    property double retryAt: 0
    function invalidate() {
        available = false; devicePath = ""; current = NaN; maximum = NaN;
        retryAt = Date.now() + 5000;
    }
    function applyValue() {
        var next = BrightnessValue.fraction(current, maximum);
        if (isFinite(next)) { available = true; value = next; }
    }
    function refresh() {
        if (!active) return;
        if (devicePath !== "") { maximumFile.reload(); currentFile.reload(); }
        else if (!discovery.running && Date.now() >= retryAt) discovery.running = true;
    }
    onActiveChanged: if (active) refresh()
    Component.onCompleted: if (active) refresh()
    Process {
        id: discovery
        command: root.discoveryCommand
        stdout: StdioCollector {
            onStreamFinished: {
                var device = BrightnessValue.device(text);
                if (!device) { root.invalidate(); return; }
                root.current = device.current; root.maximum = device.maximum; root.value = device.value;
                root.available = true; root.devicePath = device.path;
            }
        }
        onExited: (code, status) => { if (code !== 0) root.invalidate(); }
    }
    FileView {
        id: currentFile
        path: root.devicePath ? root.sysfsRoot + "/" + root.devicePath + "/brightness" : ""
        preload: true; watchChanges: false; printErrors: false
        onLoaded: {
            if (!root.devicePath) return;
            var next = BrightnessValue.number(text());
            if (!isFinite(next)) { root.invalidate(); return; }
            root.current = next; Qt.callLater(root.applyValue);
        }
        onLoadFailed: if (root.devicePath) root.invalidate()
    }
    FileView {
        id: maximumFile
        path: root.devicePath ? root.sysfsRoot + "/" + root.devicePath + "/max_brightness" : ""
        preload: true; watchChanges: false; printErrors: false
        onLoaded: {
            if (!root.devicePath) return;
            var next = BrightnessValue.number(text());
            if (!isFinite(next) || next <= 0) { root.invalidate(); return; }
            root.maximum = next; Qt.callLater(root.applyValue);
        }
        onLoadFailed: if (root.devicePath) root.invalidate()
    }
    Timer { interval: 850; repeat: true; running: root.active; onTriggered: root.refresh() }
}

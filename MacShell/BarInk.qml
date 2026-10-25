import QtQuick
import Quickshell.Io
import "BarInk.js" as Ink

// One event-driven sample per output. No screenshots are written or polled.
Item {
    id: root
    visible: false
    property var screen: null
    property bool active: false
    property bool darkMode: true
    property int barHeight: 28
    property string contextKey: ""
    property int epoch: 0
    property bool sampled: false
    property bool chosenLight: true
    property int sentEpoch: -1
    readonly property bool lightInk: active && sampled ? chosenLight : darkMode
    readonly property string status: !active ? "theme" : sampled ? "ready" : delay.running || probe.running ? "pending" : "unavailable"
    function schedule() { epoch++; if (active) delay.restart(); }
    onContextKeyChanged: schedule()
    onScreenChanged: schedule()
    onBarHeightChanged: schedule()
    onActiveChanged: { if (!active) { epoch++; sampled = false; delay.stop(); } else schedule(); }
    Component.onCompleted: schedule()
    function accept(text) {
        var parts = text.trim().split(/\s+/), values = parts.slice(1).map(Number);
        if (!active || parts.length !== 4 || Number(parts[0]) !== epoch || values.some(v => !isFinite(v) || v < 0 || v > 1)) return false;
        chosenLight = Ink.preferLight(values[0], values[1], values[2], sampled ? chosenLight : null);
        sampled = true;
        return true;
    }
    Timer {
        id: delay; interval: 180
        onTriggered: {
            if (!root.active || !root.screen || probe.running) return;
            root.sentEpoch = root.epoch;
            probe.command = ["sh", "-c", "grim -s 0.08 -g \"$1,$2 $3x$4\" - 2>/dev/null | magick - -format \"$5 %[fx:mean.r] %[fx:mean.g] %[fx:mean.b]\" info: 2>/dev/null",
                "sh", String(Math.round(root.screen.x)), String(Math.round(root.screen.y)), String(Math.max(8, Math.round(root.screen.width))), String(Math.max(8, root.barHeight)), String(root.epoch)];
            probe.running = true;
        }
    }
    Process {
        id: probe
        stdout: StdioCollector { onStreamFinished: root.accept(text) }
        onRunningChanged: if (!running && root.active && root.sentEpoch !== root.epoch) delay.restart()
    }
}

import QtQuick
import Quickshell

Scope {
    id: root
    property bool enabled: true
    property int interval: 1
    property string interfaceName: ""
    property string device: ""
    property var sample: ({})
    property var history: []
    property double lastSample: 0
    property double clock: Date.now()
    readonly property bool stale: !enabled || !service.ready || lastSample === 0 || clock - lastSample > Math.max(3500, interval * 2500)
    readonly property string error: service.error
    function configure() { service.send("configure", {interval: interval, interface: interfaceName, device: device}); }
    onEnabledChanged: lastSample = 0
    onIntervalChanged: configure()
    onInterfaceNameChanged: configure()
    onDeviceChanged: configure()
    function rate(value) {
        if (value === null || value === undefined) return "—";
        var units = ["B", "K", "M", "G"], i = 0;
        while (value >= 1000 && i < 3) { value /= 1000; i++; }
        return (value >= 100 || i === 0 ? value.toFixed(0) : value.toFixed(1)) + units[i];
    }
    function gib(value) { return ((value || 0) / 1073741824).toFixed(1); }
    JsonService {
        id: service
        script: "system_stats.py"
        enabled: root.enabled
        onConnected: root.configure()
        onReceived: m => {
            if (m.type !== "sample") return;
            root.sample = m;
            root.lastSample = Date.now();
            root.clock = root.lastSample;
            var next = root.history.filter(v => m.time - v.time <= 60);
            next.push(m);
            root.history = next.slice(-61);
        }
    }
    Timer { interval: 1000; repeat: true; running: root.enabled; onTriggered: root.clock = Date.now() }
}

import QtQuick
import Quickshell
import Quickshell.Io

Scope {
    id: root
    property bool active: false
    property bool continuous: true
    property bool ready: false
    property string bootId: ""
    property double bootMs: 0
    readonly property bool sampling: process.running
    readonly property string helper: decodeURIComponent(Qt.resolvedUrl("boot_clock.py").toString().replace(/^file:\/\//, ""))

    function start() {
        if (!active || process.running) return;
        process.command = ["python3", "-u", helper].concat(continuous ? [] : ["--once"]);
        process.running = true;
    }
    onActiveChanged: {
        restart.stop();
        if (active) start();
        else { watchdog.stop(); ready = false; process.running = false; }
    }
    onContinuousChanged: {
        if (!active) return;
        restart.stop(); watchdog.stop(); ready = false;
        if (process.running) { process.running = false; restart.restart(); }
        else start();
    }
    Component.onCompleted: if (active) start()
    Process {
        id: process
        stdout: SplitParser {
            onRead: line => {
                try {
                    var sample = JSON.parse(line);
                    if (typeof sample.bootId !== "string" || !sample.bootId ||
                            typeof sample.bootMs !== "number" || !isFinite(sample.bootMs) || sample.bootMs < 0) return;
                    root.bootId = sample.bootId;
                    root.bootMs = sample.bootMs;
                    root.ready = true;
                    if (root.continuous) watchdog.restart();
                } catch (e) { root.ready = false; }
            }
        }
        onExited: (code, status) => {
            watchdog.stop();
            if (root.active && !root.continuous && code === 0 && root.ready) return;
            root.ready = false;
            if (root.active) restart.restart();
        }
    }
    Timer { id: watchdog; interval: 2000; onTriggered: { root.ready = false; process.running = false; } }
    Timer { id: restart; interval: 2000; onTriggered: root.start() }
}

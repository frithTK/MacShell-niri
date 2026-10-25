import QtQuick
import Quickshell

Scope {
    id: root
    property bool active: false
    property string state: "choose"
    property var outputs: []
    property var microphones: []
    property var sinks: []
    property bool available: false
    property bool mixAvailable: false
    property string output: ""
    property string microphone: ""
    property string sink: ""
    property string audio: "none"
    property bool region: false
    property string geometry: ""
    property string error: ""
    property string file: ""
    property int countdown: 3
    property int seconds: 0
    property double started: 0
    readonly property bool busy: ["selecting", "countdown", "mixing", "starting", "recording", "stopping", "saving"].indexOf(state) >= 0
    readonly property bool quiet: busy
    readonly property bool recording: state === "recording"
    signal hideRequested()
    signal showRequested()
    function data() { return {output: output, microphone: microphone, sink: sink, audio: audio, region: region, geometry: geometry}; }
    function prepare() { error = ""; service.send("prepare"); }
    function select() { error = ""; service.send("select", data()); }
    function start() { error = ""; service.send("start", data()); }
    function stop() { service.send("stop"); }
    function cancel() { service.send("cancel"); }
    function timeLabel() { return Math.floor(seconds / 60) + ":" + (seconds % 60 < 10 ? "0" : "") + seconds % 60; }
    JsonService {
        id: service; script: "recording_control.py"; enabled: root.active
        onReadyChanged: if (!ready) { root.state = "error"; root.error = "Recorder service disconnected. Check partial files in Videos."; }
        onReceived: m => {
            if (m.type === "choices") {
                root.outputs = m.outputs || []; root.microphones = m.audio.microphones || []; root.sinks = m.audio.sinks || [];
                root.available = m.available; root.mixAvailable = m.mixAvailable; root.error = m.audioError || "";
                if (!root.outputs.some(o => o.name === root.output)) root.output = root.outputs.length ? root.outputs[0].name : "";
            } else if (m.type === "state") {
                var previous = root.state;
                root.state = m.state; root.seconds = m.elapsed || 0; root.countdown = m.countdown; root.error = m.error || ""; root.file = m.file || "";
                if (m.geometry) root.geometry = m.geometry;
                if (root.state === "recording" && previous !== "recording") { root.started = Date.now(); root.seconds = 0; }
                if (root.state === "selecting" || root.state === "starting" || root.state === "mixing") root.hideRequested();
                if (previous === "selecting" && root.state === "choose" || root.state === "result" || root.state === "error") root.showRequested();
            } else if (m.type === "error") { root.error = m.error; if (!root.busy) root.state = "error"; root.showRequested(); }
        }
    }
    Timer { interval: 1000; repeat: true; running: root.recording; onTriggered: service.send("status") }
}

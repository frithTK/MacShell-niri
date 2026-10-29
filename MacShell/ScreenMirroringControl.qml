import QtQuick
import "Locale" as Language
import Quickshell

Scope {
    id: root
    property bool active: false
    property bool blocked: false
    property bool watching: false
    property bool senderAvailable: false
    property bool receiverAvailable: false
    property string senderState: "off"
    property string receiverState: "off"
    property string senderError: ""
    property string receiverError: ""
    property string error: ""
    property string receiverName: "MacShell"
    property string advertisedName: "MacShell"
    property string receiverPin: ""
    property string receiverClient: ""
    property bool scanning: false
    property var devices: []
    property var streams: []
    readonly property var pending: streams.find(s => s.state === "pin_required") || null
    readonly property bool sending: streams.some(s => s.state === "streaming")
    readonly property bool connecting: ["starting", "connecting", "pin_required"].indexOf(senderState) >= 0
    readonly property bool receiving: ["starting", "waiting", "streaming"].indexOf(receiverState) >= 0
    readonly property bool quiet: sending || connecting
    readonly property string label: sending ? (streams[0].device || Language.I18n.text("ui.t_12514ad4f7ac"))
                                   : connecting ? (pending ? Language.I18n.text("ui.t_ad56c87ece8f") : Language.I18n.text("ui.t_72021eb70e91"))
                                   : receiverState === "streaming" ? Language.I18n.text("ui.t_fa8162869da5")
                                   : receiving ? Language.I18n.text("ui.t_3c95a1ae6eda") : Language.I18n.text("ui.t_5d9bbb593f62")
    signal hideRequested()
    signal showRequested()
    function observe() { service.send("watch", {enabled: watching}); }
    function refresh() { error = ""; service.send("refresh"); }
    function connectDevice(key) { if (blocked) { error = "Stop AirDrop before starting AirPlay."; return; } error = ""; service.send("connect", {key: key}); }
    function submitCredential(value) { error = ""; service.send("credential", {value: value}); }
    function disconnect() { error = ""; service.send("disconnect"); }
    function setAudio(enabled) { error = ""; service.send("audio", {enabled: enabled}); }
    function setReceiver(enabled) { if (enabled && blocked) { error = "Stop AirDrop before starting AirPlay."; return; } error = ""; service.send("receive", {enabled: enabled, name: receiverName}); }
    onWatchingChanged: observe()
    JsonService {
        id: service; script: "screen_mirroring.py"; enabled: root.active
        onConnected: root.observe()
        onReadyChanged: if (!ready) {
            root.senderState = "off"; root.receiverState = "off"; root.streams = [];
            root.receiverPin = ""; root.receiverClient = ""; root.error = error;
        }
        onReceived: m => {
            if (m.type === "error") { root.error = m.error || Language.I18n.text("ui.t_201d3e7d7c3c"); root.showRequested(); return; }
            if (m.type !== "state") return;
            var wasPending = root.pending !== null;
            var previousPin = root.receiverPin;
            var previousState = root.senderState;
            var previousSenderError = root.senderError;
            var previousReceiverError = root.receiverError;
            root.senderAvailable = m.senderAvailable; root.receiverAvailable = m.receiverAvailable;
            root.senderState = m.senderState; root.receiverState = m.receiverState;
            root.senderError = m.senderError || ""; root.receiverError = m.receiverError || "";
            root.devices = m.devices || []; root.streams = m.streams || [];
            root.receiverPin = m.receiverPin || ""; root.receiverClient = m.receiverClient || "";
            root.advertisedName = m.receiverName || "MacShell"; root.scanning = !!m.scanning;
            if (root.pending && !wasPending || root.receiverPin !== "" && root.receiverPin !== previousPin
                    || root.senderError !== "" && root.senderError !== previousSenderError
                    || root.receiverError !== "" && root.receiverError !== previousReceiverError)
                root.showRequested();
            // Leave the portal's screen/window picker unobstructed.
            else if (root.senderState === "connecting" && previousState !== "connecting") root.hideRequested();
        }
    }
}

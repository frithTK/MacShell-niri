import QtQuick
import Quickshell

Scope {
    id: root
    property bool enabled: false
    property string storePath: ""
    property string soundDirectory: ""
    property var snapshot: null
    property bool initialized: false
    property var pending: null
    readonly property bool ready: service.ready && initialized
    readonly property bool busy: pending !== null
    readonly property string serviceError: service.error
    property string error: ""
    property var sounds: []
    property bool showBuiltins: true
    property var soundRequests: ({})
    property string soundError: ""
    property string previewId: ""
    signal completed(bool success, var result, string error)
    signal soundDeleted(string soundId)

    function soundRequest(action, data) {
        if (!ready) return false;
        var request = service.send(action, data || {});
        if (request < 0) return false;
        var requests = Object.assign({}, soundRequests);
        requests[request] = {action: action, soundId: data && data.soundId || ""}; soundRequests = requests;
        return true;
    }
    function refreshSounds() { return soundRequest("sounds", {}); }
    function setBuiltinsVisible(visible) { return soundRequest("set-builtins-visible", {visible: visible}); }
    function previewSound(id, options, kind) { return soundRequest("preview-sound", {soundId: id, soundOptions: options || null, kind: kind || ""}); }
    function stopPreview() { return soundRequest("stop-preview", {}); }
    function favoriteSound(id, favorite) { return soundRequest("favorite-sound", {soundId: id, favorite: favorite}); }
    function deleteSound(id) { return soundRequest("delete-sound", {soundId: id}); }
    function renameSound(id, name) { return soundRequest("rename-sound", {soundId: id, name: name}); }

    function submit(action, args) {
        if (!ready || busy) return false;
        pending = {action: action, args: args || {}, envelope: null, stage: "prepare", requestId: -1};
        pending.requestId = service.send("prepare", {});
        if (pending.requestId < 0) { pending = null; return false; }
        return true;
    }
    onEnabledChanged: if (!enabled && pending) fail("Clock service was disabled.")
    function fail(message) {
        pending = null;
        error = message;
        completed(false, null, message);
    }
    function resumePending() {
        if (!pending || pending.stage !== "reconnect") return;
        if (!pending.envelope) {
            pending.stage = "prepare";
            pending.requestId = service.send("prepare", {});
            return;
        }
        if (pending.action === "claim-sound") {
            fail("Sound claim outcome is unknown; the event remains visible.");
            return;
        }
        var age = snapshot.bootNowMs - pending.envelope.issuedBootMs;
        if (snapshot.bootId !== pending.envelope.bootId || age < 0 || age > 600000) {
            fail("The command expired; review the current Clock state.");
            return;
        }
        pending.stage = "command";
        pending.requestId = service.send("command", pending.envelope);
    }
    JsonService {
        id: service
        script: "clock_service.py"
        arguments: ["--store", root.storePath].concat(root.soundDirectory ? ["--audio-dir", root.soundDirectory] : [])
        enabled: root.enabled && root.storePath !== ""
        onConnected: service.send("load", {})
        onReadyChanged: {
            if (!ready) {
                root.initialized = false;
                root.previewId = ""; root.soundRequests = ({});
                if (root.pending) root.pending.stage = "reconnect";
            }
        }
        onReceived: message => {
            if (message.type === "sounds") {
                root.sounds = message.sounds || []; root.soundError = message.warning || "";
                if (typeof message.showBuiltins === "boolean") root.showBuiltins = message.showBuiltins;
                var completedSoundRequest = root.soundRequests[message.id];
                if (completedSoundRequest && completedSoundRequest.action === "delete-sound") root.soundDeleted(completedSoundRequest.soundId);
                var requests = Object.assign({}, root.soundRequests); delete requests[message.id]; root.soundRequests = requests;
            } else if (message.type === "sound-preview") {
                root.previewId = message.playing ? message.soundId : ""; root.soundError = message.error || "";
                var previewRequests = Object.assign({}, root.soundRequests); delete previewRequests[message.id]; root.soundRequests = previewRequests;
            } else if (message.type === "result" && root.soundRequests[message.id]) {
                if (root.soundRequests[message.id].action === "preview-sound") root.previewId = "";
                var pendingSounds = Object.assign({}, root.soundRequests); delete pendingSounds[message.id]; root.soundRequests = pendingSounds;
                root.soundError = message.error || "Clock sound operation failed";
            } else if (message.type === "state") {
                root.snapshot = message;
                root.initialized = true;
                if (root.error !== "Clock sound failed; using the built-in sound" ||
                        !message.timing || !message.timing.completion) root.error = "";
                root.resumePending();
            } else if (message.type === "prepared" && root.pending && root.pending.stage === "prepare"
                       && message.id === root.pending.requestId) {
                var args = Object.assign({}, root.pending.args);
                if ((root.pending.action === "start" || root.pending.action === "repeat-timer") && !args.sessionId) args.sessionId = message.sessionId;
                root.pending.envelope = {id: message.commandId, bootId: message.bootId,
                                         issuedBootMs: message.issuedBootMs, revision: message.revision,
                                         action: root.pending.action, args: args};
                root.pending.stage = "command";
                root.pending.requestId = service.send("command", root.pending.envelope);
            } else if (message.type === "result" && root.pending && root.pending.stage === "command"
                       && message.id === root.pending.requestId) {
                var success = !!message.success, result = message.result || null, detail = message.error || "";
                root.pending = null;
                root.error = detail;
                root.completed(success, result, detail);
                if (!success) service.send("load", {});
            } else if (message.type === "result" && root.pending && root.pending.stage === "prepare"
                       && message.id === root.pending.requestId && !message.success) {
                root.fail(message.error || "Clock service could not prepare the command.");
                service.send("load", {});
            } else if (message.type === "error") {
                root.error = message.error || "Clock service error";
            }
        }
    }
}

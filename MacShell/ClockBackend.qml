import QtQuick
import Quickshell
import "ClockDisplay.js" as ClockDisplay

Scope {
    id: root
    property bool enabled: false
    property string storePath: ""
    property string soundDirectory: ""
    readonly property alias controller: client
    readonly property bool ready: client.ready
    readonly property bool busy: client.busy
    readonly property bool stale: !client.ready && client.snapshot !== null
    readonly property string error: client.error || client.serviceError
    readonly property var snapshot: client.snapshot
    readonly property var timing: snapshot && snapshot.timing ? snapshot.timing : null
    readonly property var timer: snapshot && snapshot.timer ? snapshot.timer : ({state: "idle", total: 300000, left: 300000, label: ""})
    readonly property var stopwatch: snapshot && snapshot.sw ? snapshot.sw : ({running: false, acc: 0, startAt: 0, laps: []})
    readonly property var alarms: snapshot && snapshot.alarms ? snapshot.alarms : []
    readonly property var cities: snapshot && snapshot.cities ? snapshot.cities : []
    readonly property var recents: snapshot && snapshot.recents ? snapshot.recents : []
    readonly property var completion: timing && timing.completion ? timing.completion : null
    readonly property var ringing: snapshot && snapshot.ringing ? snapshot.ringing : null
    readonly property var display: timing ? ({version: 2, timing: timing, timer: timer, sw: stopwatch}) : null
    readonly property string timerStatus: ClockDisplay.status(timing, timing ? timing.timer : null, clockTime.ready, clockTime.bootId)
    readonly property string stopwatchStatus: ClockDisplay.status(timing, timing ? timing.stopwatch : null, clockTime.ready, clockTime.bootId)
    readonly property double timerRemaining: ClockDisplay.timerRemaining(display, Date.now(), clockTime.ready, clockTime.bootId, clockTime.bootMs)
    readonly property double stopwatchElapsed: ClockDisplay.stopwatchElapsed(display, Date.now(), clockTime.ready, clockTime.bootId, clockTime.bootMs)
    property string pendingAction: ""
    property var queuedEvent: null
    signal completed(string action, bool success, var result, string error)

    function submit(action, args) {
        if (!client.ready || client.busy) return false;
        pendingAction = action;
        if (client.submit(action, args || {})) return true;
        pendingAction = "";
        return false;
    }
    function startTimer(duration, label, replace, soundId, soundOptions) {
        if (timing && timing.timer && timing.timer.state !== "idle" && !replace) return false;
        return submit("start", {durationMs: duration, label: label || "", replace: !!replace, soundId: soundId || "", soundOptions: soundOptions || null});
    }
    function timerAction(action) {
        if (!timing || !timing.timer) return false;
        return submit(action, {sessionId: timing.timer.sessionId});
    }
    function stopwatchAction(action) {
        if (!timing || !timing.stopwatch) return false;
        return submit("stopwatch-" + action, {sessionId: timing.stopwatch.sessionId});
    }
    function eventAction(action) {
        if (!completion) return false;
        if (client.ready && client.busy && snapshot && snapshot.bootId) {
            queuedEvent = {action: action, eventId: completion.eventId, bootId: snapshot.bootId,
                           issuedBootMs: snapshot.bootNowMs};
            return true;
        }
        return submit(action, {eventId: completion.eventId});
    }
    function flushQueuedEvent() {
        if (!queuedEvent || !client.ready || client.busy || !snapshot) return;
        var request = queuedEvent;
        queuedEvent = null;
        var age = snapshot.bootNowMs - request.issuedBootMs;
        if (!completion || completion.eventId !== request.eventId || snapshot.bootId !== request.bootId ||
                age < 0 || age > 600000) return;
        submit(request.action, {eventId: request.eventId});
    }
    function repeatTimer() {
        if (!completion) return false;
        return submit("repeat-timer", {eventId: completion.eventId});
    }
    function patchSettings(patch) { return submit("patch-settings", {patch: patch}); }

    ClockClient {
        id: client
        enabled: root.enabled
        storePath: root.storePath
        soundDirectory: root.soundDirectory
        onCompleted: (success, result, error) => {
            var action = root.pendingAction;
            root.pendingAction = "";
            root.completed(action, success, result, error);
        }
        onSnapshotChanged: Qt.callLater(root.flushQueuedEvent)
    }
    ClockBoot {
        id: clockTime
        active: {
            if (!root.enabled || !root.timing) return false;
            var timer = root.timing.timer, sw = root.timing.stopwatch;
            return !!((timer && (timer.state === "running" || timer.state === "paused")) ||
                      (sw && (sw.state === "running" || sw.state === "paused")));
        }
        continuous: {
            if (!root.timing) return false;
            var timer = root.timing.timer, sw = root.timing.stopwatch;
            return !!((timer && timer.state === "running") || (sw && sw.state === "running"));
        }
    }
}

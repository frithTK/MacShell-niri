import QtQuick

QtObject {
    id: state
    property bool ready: false
    property bool visible: false
    property string kind: "volume"
    property real value: 0
    property bool muted: false
    property int duration: 1500
    property var quietUntil: ({})
    signal shown(string kind, real value, bool muted)

    function quiet(kind, milliseconds) {
        quietUntil[kind] = Math.max(quietUntil[kind] || 0, Date.now() + milliseconds);
    }

    // Explicit key requests bypass startup and slider suppression. Suppression
    // still absorbs the asynchronous PipeWire/backlight echo of that request.
    function show(kind, value, muted = false, explicit = false) {
        if (["volume", "brightness", "microphone"].indexOf(kind) < 0 || !isFinite(value)) return false;
        if (!explicit && (!ready || Date.now() < (quietUntil[kind] || 0))) return false;
        state.kind = kind;
        state.value = Math.max(0, Math.min(kind === "volume" ? 1.5 : 1, value));
        state.muted = muted;
        visible = true;
        hideTimer.restart();
        shown(kind, state.value, muted);
        return true;
    }

    property Timer hideTimer: Timer {
        interval: state.duration
        onTriggered: state.visible = false
    }
    property Timer startupTimer: Timer {
        interval: 1200; running: true
        onTriggered: state.ready = true
    }
}

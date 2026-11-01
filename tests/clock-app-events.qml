import QtQuick
import QtTest
import Quickshell
import "." as Port
import "Locale" as Language

ShellRoot {
    id: root
    property int phase: 0
    property int waits: 0
    property string firstEvent: ""
    property string firstSession: ""
    function find(item, name) {
        if (!item) return null;
        if (item.objectName === name && item.visible && item.enabled) return item;
        for (var child of item.children || []) {
            var found = find(child, name);
            if (found) return found;
        }
        return null;
    }
    function hasText(item, value) {
        if (!item) return false;
        if (typeof item.text === "string" && item.text === value) return true;
        for (var child of item.children || []) if (hasText(child, value)) return true;
        return false;
    }
    Port.ClockApp { id: clock }
    TestEvent { id: events }
    Connections {
        target: clock.testBackend
        function onCompleted(action, success, result, error) { if (!success) { console.error("CLOCK_EVENTS_FAIL " + action + " " + error); Qt.exit(1); } }
    }
    Timer {
        interval: 100; running: true; repeat: true
        onTriggered: {
            if (!clock.loaded || !clock.clockControlsReady) return;
            if (clock.testClockWindow.visible) { console.error("CLOCK_EVENTS_FAIL window opened"); Qt.exit(1); return; }
            if (root.phase === 0) {
                Language.I18n.language = "ru";
                root.phase = 1;
                if (!clock.startTimer(1200, "Native timer")) { console.error("CLOCK_EVENTS_FAIL start"); Qt.exit(1); }
            } else if (root.phase === 1 && clock.timer.state === "running") {
                root.firstSession = clock.testBackend.timing.timer.sessionId;
                root.phase = 2;
            } else if (root.phase === 2 && clock.ringing && clock.ringing.kind === "timer") {
                if (++root.waits < 5) return;
                var repeatButton = root.find(clock.testClockBanner.contentItem, "clockRingAction_repeat");
                if (!repeatButton) return;
                if (!root.hasText(repeatButton, "Повторить")) { console.error("CLOCK_EVENTS_FAIL translated repeat"); Qt.exit(1); return; }
                root.firstEvent = clock.ringing.eventId; root.waits = 0; root.phase = 3;
                events.mouseClick(repeatButton, repeatButton.width / 2, repeatButton.height / 2, Qt.LeftButton, Qt.NoModifier, 0);
            } else if (root.phase === 3 && !clock.ringing && clock.timer.state === "running") {
                if (clock.testBackend.timing.timer.sessionId === root.firstSession) { console.error("CLOCK_EVENTS_FAIL repeat identity"); Qt.exit(1); return; }
                Language.I18n.language = "en";
                root.phase = 4;
            } else if (root.phase === 4 && clock.ringing && clock.ringing.kind === "timer") {
                if (++root.waits < 5) return;
                if (clock.ringing.eventId === root.firstEvent) { console.error("CLOCK_EVENTS_FAIL event identity"); Qt.exit(1); return; }
                var stopButton = root.find(clock.testClockBanner.contentItem, "clockRingAction_stop");
                if (!stopButton) return;
                if (!root.hasText(stopButton, "Stop")) { console.error("CLOCK_EVENTS_FAIL translated stop"); Qt.exit(1); return; }
                root.phase = 5;
                events.mouseClick(stopButton, stopButton.width / 2, stopButton.height / 2, Qt.LeftButton, Qt.NoModifier, 0);
            } else if (root.phase === 5 && !clock.ringing && clock.timer.state === "idle") {
                console.log("CLOCK_EVENTS_APP_PASS"); Qt.exit(0);
            }
        }
    }
    Timer { interval: 18000; running: true; onTriggered: { console.error("CLOCK_EVENTS_FAIL timeout phase=" + root.phase + " error=" + clock.clockMessage); Qt.exit(1); } }
}

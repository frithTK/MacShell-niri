import QtQuick
import Quickshell
import "." as Port

ShellRoot {
    id: root
    property int phase: 0
    property real pausedValue: 0
    property int pausedChecks: 0
    Port.ClockApp { id: clock }
    Connections {
        target: clock.testBackend
        function onCompleted(action, success, result, error) { if (!success) console.error("CLOCK_APP_COMMAND_FAIL " + action + " " + error); }
    }
    Timer {
        interval: 100; running: true; repeat: true
        onTriggered: {
            if (!clock.loaded || !clock.clockControlsReady) return;
            if (root.phase === 0) {
                if (!clock.managedClock) { console.error("CLOCK_APP_FAIL mode"); Qt.exit(1); return; }
                root.phase = 1;
                var hour = (new Date().getHours() + 2) % 24;
                if (!clock.addAlarm(hour, 5, "Alarm test", [1, 2, 3, 4, 5, 6, 0])) { console.error("CLOCK_APP_FAIL alarm"); Qt.exit(1); }
            } else if (root.phase === 1 && clock.alarms.length === 1) {
                root.phase = 2;
                if (!clock.addCity("Moscow", "Europe/Moscow")) { console.error("CLOCK_APP_FAIL city"); Qt.exit(1); }
            } else if (root.phase === 2 && clock.cities.length === 5) {
                root.phase = 3;
                if (!clock.startTimer(30000, "Tea")) { console.error("CLOCK_APP_FAIL timer start"); Qt.exit(1); }
            } else if (root.phase === 3 && clock.timer.state === "running" && clock.timerLeft() > 0 && clock.timerLeft() <= 30000) {
                if (clock.recents[0] !== 30000) { console.error("CLOCK_APP_FAIL recents"); Qt.exit(1); return; }
                root.phase = 4; clock.pauseTimer();
            } else if (root.phase === 4 && clock.timer.state === "paused") {
                if (!root.pausedChecks) root.pausedValue = clock.timerLeft();
                if (clock.timerLeft() !== root.pausedValue) { console.error("CLOCK_APP_FAIL paused"); Qt.exit(1); return; }
                if (++root.pausedChecks < 3) return;
                root.phase = 5; clock.resumeTimer();
            } else if (root.phase === 5 && clock.timer.state === "running") {
                root.phase = 6; clock.cancelTimer();
            } else if (root.phase === 6 && clock.timer.state === "idle") {
                root.phase = 7; clock.swStart();
            } else if (root.phase === 7 && clock.sw.running) {
                root.phase = 8; clock.swLap();
            } else if (root.phase === 8 && clock.sw.laps.length === 1) {
                root.phase = 9; clock.swStop();
            } else if (root.phase === 9 && !clock.sw.running && clock.sw.acc >= clock.sw.laps[0]) {
                root.phase = 10; clock.saveNow();
                console.log("CLOCK_APP_MANAGED_PASS"); Qt.exit(0);
            }
        }
    }
    Timer { interval: 12000; running: true; onTriggered: { console.error("CLOCK_APP_FAIL timeout phase=" + root.phase + " loaded=" + clock.loaded + " ready=" + clock.clockControlsReady + " error=" + clock.testBackend.error + " snapshot=" + JSON.stringify(clock.testBackend.snapshot)); Qt.exit(1); } }
}

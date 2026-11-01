import QtQuick
import Quickshell
import "." as Port

ShellRoot {
    id: root
    property int phase: 0
    property double pausedValue: 0
    property int pauseChecks: 0
    Port.ClockBackend {
        id: clock
        enabled: true
        storePath: Quickshell.env("MACSHELL_CLOCK_TEST_STORE")
        onCompleted: (action, success, result, error) => {
            if (!success) { console.error("CLOCK_BACKEND_FAIL " + action + ": " + error); Qt.exit(1); }
        }
    }
    Timer {
        interval: 100; running: true; repeat: true
        onTriggered: {
            if (!clock.ready || clock.busy || !clock.timing) return;
            if (root.phase === 0) {
                root.phase = 1;
                if (!clock.startTimer(5000, "Tea", false)) { console.error("CLOCK_BACKEND_FAIL start"); Qt.exit(1); }
            } else if (root.phase === 1 && clock.timing.timer.state === "running" && clock.timerStatus === "normal") {
                if (clock.timerRemaining <= 0 || clock.timerRemaining > 5000 || clock.recents[0] !== 5000) {
                    console.error("CLOCK_BACKEND_FAIL remaining"); Qt.exit(1); return;
                }
                root.phase = 2;
                if (!clock.timerAction("pause")) { console.error("CLOCK_BACKEND_FAIL pause"); Qt.exit(1); }
            } else if (root.phase === 2 && clock.timing.timer.state === "paused") {
                if (!root.pauseChecks) root.pausedValue = clock.timerRemaining;
                if (clock.timerRemaining !== root.pausedValue) { console.error("CLOCK_BACKEND_FAIL paused countdown"); Qt.exit(1); return; }
                if (++root.pauseChecks < 3) return;
                root.phase = 3;
                if (!clock.stopwatchAction("start")) { console.error("CLOCK_BACKEND_FAIL stopwatch start"); Qt.exit(1); }
            } else if (root.phase === 3 && clock.timing.stopwatch.state === "running" && clock.stopwatchStatus === "normal") {
                root.phase = 4;
                if (!clock.stopwatchAction("lap")) { console.error("CLOCK_BACKEND_FAIL lap"); Qt.exit(1); }
            } else if (root.phase === 4 && clock.stopwatch.laps.length === 1) {
                root.phase = 5;
                if (!clock.timerAction("resume")) { console.error("CLOCK_BACKEND_FAIL resume"); Qt.exit(1); }
            } else if (root.phase === 5 && clock.timing.timer.state === "running") {
                root.phase = 6;
                if (!clock.timerAction("cancel")) { console.error("CLOCK_BACKEND_FAIL cancel"); Qt.exit(1); }
            } else if (root.phase === 6 && clock.timing.timer.state === "idle") {
                root.phase = 7;
                if (!clock.stopwatchAction("pause")) { console.error("CLOCK_BACKEND_FAIL stopwatch pause"); Qt.exit(1); }
            } else if (root.phase === 7 && clock.timing.stopwatch.state === "paused") {
                if (clock.stopwatchElapsed < clock.stopwatch.laps[0]) { console.error("CLOCK_BACKEND_FAIL elapsed"); Qt.exit(1); return; }
                root.phase = 8;
                if (!clock.stopwatchAction("reset")) { console.error("CLOCK_BACKEND_FAIL stopwatch reset"); Qt.exit(1); }
            } else if (root.phase === 8 && clock.timing.stopwatch.state === "idle") {
                if (clock.stopwatch.laps.length !== 0) { console.error("CLOCK_BACKEND_FAIL reset laps"); Qt.exit(1); return; }
                console.log("CLOCK_BACKEND_INTEGRATION_PASS"); Qt.exit(0);
            }
        }
    }
    Timer { interval: 15000; running: true; onTriggered: { console.error("CLOCK_BACKEND_FAIL timeout phase=" + root.phase + " error=" + clock.error); Qt.exit(1); } }
}

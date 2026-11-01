import QtQuick
import Quickshell
import "." as Port

ShellRoot {
    id: root
    property int phase: 0
    Port.ClockApp { id: clock }
    Timer {
        interval: 60; running: true; repeat: true
        onTriggered: {
            if (!clock.clockControlsReady) return;
            if (root.phase === 0) {
                clock.timerSoundId = "builtin-chime-01";
                clock.timerSoundOptions = {volume: 42, fadeMs: 5000, startMs: 2000, durationMs: 10000, repeat: false};
                if (!clock.startTimer(5000, "Tea")) { console.error("CLOCK_PRESETS_FAIL start"); Qt.exit(1); return; }
                root.phase = 1;
            } else if (root.phase === 1 && clock.timer.state === "running") {
                clock.cancelTimer(); root.phase = 2;
            } else if (root.phase === 2 && clock.timer.state === "idle") {
                clock.timerSoundId = "builtin-urgent-10"; clock.timerSoundOptions = {volume: 99};
                if (!clock.startRecent(5000)) { console.error("CLOCK_PRESETS_FAIL recent"); Qt.exit(1); return; }
                root.phase = 3;
            } else if (root.phase === 3 && clock.timer.state === "running") {
                var timer = clock.testBackend.timing.timer;
                if (timer.soundId !== "builtin-chime-01" || timer.soundOptions.volume !== 42 ||
                        timer.soundOptions.fadeMs !== 5000 || timer.soundOptions.startMs !== 2000 ||
                        timer.soundOptions.durationMs !== 10000 || timer.soundOptions.repeat !== false) {
                    console.error("CLOCK_PRESETS_FAIL options " + JSON.stringify(timer)); Qt.exit(1); return;
                }
                clock.cancelTimer(); root.phase = 4;
            } else if (root.phase === 4 && clock.timer.state === "idle") {
                console.log("CLOCK_PRESETS_PASS"); Qt.exit(0);
            }
        }
    }
    Timer { interval: 8000; running: true; onTriggered: { console.error("CLOCK_PRESETS_FAIL timeout " + root.phase); Qt.exit(1); } }
}

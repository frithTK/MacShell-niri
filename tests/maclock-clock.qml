property int clockTestPhase: 0
property int clockTestWaits: 0
Timer {
    interval: 100; repeat: true; running: true
    onTriggered: {
        if (++ls.clockTestWaits > 150) { console.error("MACLOCK_CLOCK_FAIL timeout"); Qt.exit(1); return; }
        if (!ls.clockSt) return;
        if (ls.clockTestPhase === 0 && ls.st.bootClockReady && ls.timerStatus === "normal") {
            if (Math.abs(liveCard.remain - (ls.clockTiming.timer.deadlineBootMs - ls.st.bootClockMs)) > 5 || liveCard.remain > 65000) {
                console.error("MACLOCK_CLOCK_FAIL boot timer"); Qt.exit(1); return;
            }
            ls.clockTestPhase = 1; console.log("MACLOCK_CLOCK_NORMAL");
        } else if (ls.clockTestPhase === 1 && ls.timerStatus === "recovery") {
            if (liveCard.remain !== 42000 || liveClockLabel.text.indexOf(Language.I18n.text("clock.recovery_required")) < 0) {
                console.error("MACLOCK_CLOCK_FAIL recovery"); Qt.exit(1); return;
            }
            ls.clockTestPhase = 2; console.log("MACLOCK_CLOCK_RECOVERY");
        } else if (ls.clockTestPhase === 2 && !ls.clockTiming && ls.clockSt.timer && ls.clockSt.timer.label === "Legacy") {
            if (ls.timerStatus !== "legacy" || liveCard.remain < 10000 || liveCard.remain > 25000) {
                console.error("MACLOCK_CLOCK_FAIL legacy"); Qt.exit(1); return;
            }
            ls.clockTestPhase = 3; console.log("MACLOCK_CLOCK_LEGACY");
        } else if (ls.clockTestPhase === 3 && ls.clockTiming && ls.clockTiming.stopwatch && ls.stopwatchStatus === "normal" && ls.st.bootClockReady) {
            var sw = ls.clockTiming.stopwatch;
            if (ls.liveKind !== "sw" || liveCard.swMs !== sw.accumulatedMs + ls.st.bootClockMs - sw.startedBootMs) {
                console.error("MACLOCK_CLOCK_FAIL stopwatch"); Qt.exit(1); return;
            }
            ls.clockTestPhase = 4; console.log("MACLOCK_CLOCK_STOPWATCH");
        } else if (ls.clockTestPhase === 4 && ls.stopwatchStatus === "recovery") {
            if (liveCard.swMs !== 2400 || liveClockLabel.text.indexOf(Language.I18n.text("clock.recovery_required")) < 0) {
                console.error("MACLOCK_CLOCK_FAIL stopwatch recovery"); Qt.exit(1); return;
            }
            console.log("MACLOCK_CLOCK_PASS"); Qt.exit(0);
        }
    }
}

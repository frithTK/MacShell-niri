import QtQuick
import QtTest
import Quickshell
import "." as Port
import "Locale" as Language

ShellRoot {
    id: root
    property int phase: 0
    property int settleTicks: 0
    property bool capturing: false
    property var captureAction: null
    property string captureName: ""
    readonly property string captureDir: Quickshell.env("MACSHELL_CLOCK_CAPTURE_DIR")
    function capture(name, after) {
        if (!captureDir) { after(); return; }
        capturing = true;
        captureName = name; captureAction = after; captureDelay.restart();
    }
    Timer {
        id: captureDelay; interval: 650
        onTriggered: clock.testClockWindow.contentItem.grabToImage(result => {
            var theme = Quickshell.env("MACSHELL_CLOCK_TEST_THEME") === "light" ? "light" : "dark";
            var language = Quickshell.env("MACSHELL_CLOCK_TEST_LANGUAGE") === "ru" ? "ru-" : "";
            if (!result.saveToFile(root.captureDir + "/clock-" + root.captureName + "-" + language + theme + ".png")) {
                console.error("CLOCK_RECOVERY_APP_FAIL screenshot"); Qt.exit(1); return;
            }
            var next = root.captureAction; root.captureAction = null; root.capturing = false; next();
        })
    }
    function findVisible(item, name) {
        if (!item) return null;
        if (item.objectName === name && item.visible && item.enabled) return item;
        for (var child of item.children || []) {
            var found = findVisible(child, name);
            if (found) return found;
        }
        return null;
    }
    QtObject { id: demoDock; property bool darkMode: Quickshell.env("MACSHELL_CLOCK_TEST_THEME") !== "light"; property string fontFamily: "Inter Variable"; property color accent: "#0A84FF" }
    QtObject { id: demoHub; property var dock: demoDock; property var bar: null }
    Port.ClockApp { id: clock; hub: demoHub }
    Component.onCompleted: if (Quickshell.env("MACSHELL_CLOCK_TEST_LANGUAGE") === "ru") Language.I18n.language = "ru"
    TestEvent { id: events }
    Connections {
        target: clock.testBackend
        function onCompleted(action, success, result, error) { if (!success) { console.error("CLOCK_RECOVERY_APP_FAIL " + action + " " + error); Qt.exit(1); } }
    }
    Timer {
        interval: 100; running: true; repeat: true
        onTriggered: {
            if (root.capturing || !clock.loaded || !clock.clockControlsReady) return;
            var timing = clock.testBackend.timing;
            if (!timing) return;
            if (root.phase === 0) {
                clock.open("timers"); root.phase = 1;
            } else if (root.phase === 1 && timing.legacySnoozesRecovery.length === 1) {
                var snooze = root.findVisible(clock.testClockWindow.contentItem, "snoozeResume-" + timing.legacySnoozesRecovery[0].id);
                if (!snooze) return;
                root.phase = 2; root.capture("snooze-recovery", function() { events.mouseClick(snooze, snooze.width / 2, snooze.height / 2, Qt.LeftButton, Qt.NoModifier, 0); });
            } else if (root.phase === 2 && timing.legacySnoozesRecovery.length === 0 && timing.timer.state === "recovery") {
                var timerButton = root.findVisible(clock.testClockWindow.contentItem, "clockRecoveryResume");
                if (!timerButton) return;
                root.phase = 3; root.capture("timer-recovery", function() { events.mouseClick(timerButton, timerButton.width / 2, timerButton.height / 2, Qt.LeftButton, Qt.NoModifier, 0); });
            } else if (root.phase === 3 && timing.timer.state === "running") {
                clock.open("stopwatch"); root.phase = 4;
            } else if (root.phase === 4 && timing.stopwatch.state === "recovery") {
                var reset = root.findVisible(clock.testClockWindow.contentItem, "clockRecoveryRestart");
                if (!reset || reset.text !== Language.I18n.text("clock.recovery_reset")) return;
                root.phase = 5; root.capture("stopwatch-recovery", function() { events.mouseClick(reset, reset.width / 2, reset.height / 2, Qt.LeftButton, Qt.NoModifier, 0); });
            } else if (root.phase === 5 && timing.stopwatch.state === "idle") {
                root.phase = 6; clock.cancelTimer();
            } else if (root.phase === 6 && timing.timer.state === "idle") {
                clock.open("alarms"); root.settleTicks = 0; root.phase = 7;
            } else if (root.phase === 7 && timing.missedSnoozes && timing.missedSnoozes.length === 1) {
                if (++root.settleTicks < 6) return;
                var dismiss = root.findVisible(clock.testClockWindow.contentItem, "clockMissedDismiss-" + timing.missedSnoozes[0].id);
                if (!dismiss) return;
                root.phase = 8; root.capturing = true;
                clock.testClockWindow.contentItem.grabToImage(function() {
                    root.capturing = false;
                    events.mouseClick(dismiss, dismiss.width / 2, dismiss.height / 2, Qt.LeftButton, Qt.NoModifier, 0);
                });
            } else if (root.phase === 8 && timing.missedSnoozes.length === 0) {
                console.log("CLOCK_RECOVERY_APP_PASS"); Qt.exit(0);
            }
        }
    }
    Timer { interval: 15000; running: true; onTriggered: { console.error("CLOCK_RECOVERY_APP_FAIL timeout phase=" + root.phase + " message=" + clock.clockMessage); Qt.exit(1); } }
}

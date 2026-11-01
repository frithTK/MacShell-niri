import QtQuick
import QtTest
import "../../MacShell" as Port
import "../../MacShell/Locale" as Language

TestCase {
    id: test
    name: "ClockStateRecovery"
    when: windowShown
    width: 680; height: 500; visible: true
    QtObject {
        id: fakeBackend
        property bool ready: true
        property bool busy: false
        property string action: ""
        property var timing: ({timer: {state: "recovery", remainingCheckpointMs: 125000, checkpointWallMs: 1000000},
                               stopwatch: {state: "recovery", elapsedCheckpointMs: 2000, checkpointWallMs: 1000000}})
        function timerAction(value) { action = "timer:" + value; return true; }
        function stopwatchAction(value) { action = "stopwatch:" + value; return true; }
    }
    Component { id: component; Port.ClockStateRecovery { width: 600; backend: fakeBackend; wallNow: 1120000 } }
    function init() {
        fakeBackend.ready = true; fakeBackend.busy = false; fakeBackend.action = ""; Language.I18n.language = "en";
        fakeBackend.timing = {timer: {state: "recovery", remainingCheckpointMs: 125000, checkpointWallMs: 1000000},
                          stopwatch: {state: "recovery", elapsedCheckpointMs: 2000, checkpointWallMs: 1000000}};
    }
    function cleanup() { Language.I18n.language = "en"; }
    function test_timer_decisions_and_checkpoint_age() {
        var item = createTemporaryObject(component, test, {kind: "timer"});
        tryVerify(() => item.implicitHeight > 100);
        compare(item.duration(125000), "02:05");
        verify(item.savedCaption().indexOf("2 minutes") >= 0);
        mouseClick(findChild(item, "clockRecoveryResume")); compare(fakeBackend.action, "timer:recover-remainder");
        mouseClick(findChild(item, "clockRecoveryRestart")); compare(fakeBackend.action, "timer:recover-restart");
        mouseClick(findChild(item, "clockRecoveryCancel")); compare(fakeBackend.action, "timer:cancel");
        fakeBackend.busy = true; compare(findChild(item, "clockRecoveryResume").enabled, false);
    }
    function test_stopwatch_and_localization() {
        var item = createTemporaryObject(component, test, {kind: "stopwatch", darkMode: false});
        tryVerify(() => item.implicitHeight > 100);
        compare(findChild(item, "clockRecoveryCancel").visible, false);
        mouseClick(findChild(item, "clockRecoveryResume")); compare(fakeBackend.action, "stopwatch:recover-resume");
        mouseClick(findChild(item, "clockRecoveryRestart")); compare(fakeBackend.action, "stopwatch:reset");
        Language.I18n.language = "ru";
        compare(findChild(item, "clockRecoveryResume").text, "Продолжить с сохранённого времени");
        verify(item.savedCaption().indexOf("2 минуты") >= 0);
    }
    function test_unknown_and_backward_wall_clock() {
        var item = createTemporaryObject(component, test, {kind: "timer"});
        item.wallNow = 500000;
        verify(item.savedCaption().indexOf("system clock may have changed") >= 0);
        fakeBackend.timing = {timer: {state: "recovery", remainingCheckpointMs: 1000}};
        compare(item.savedCaption(), "The checkpoint time is unavailable.");
    }
}

import QtQuick
import QtTest
import "../../MacShell" as Port
import "../../MacShell/Locale" as Language

TestCase {
    id: test
    name: "ClockSnoozeRecovery"
    when: windowShown
    width: 600; height: 550; visible: true
    QtObject {
        id: controller
        property bool ready: true
        property bool busy: false
        property string error: ""
        property var lastCommand: null
        property var snapshot: ({timing: {legacySnoozesRecovery: [
            {id: "first", label: "Tea", remainingMs: 125000, capturedWallMs: 1793010030000},
            {id: "second", label: "", remainingMs: 0, capturedWallMs: 1793010030000}
        ]}})
        function submit(action, args) { lastCommand = {action: action, args: args}; return true; }
    }
    Component { id: component; Port.ClockSnoozeRecovery { width: 540; clock: controller } }
    function init() {
        controller.ready = true; controller.busy = false; controller.error = ""; controller.lastCommand = null;
        Language.I18n.language = "en";
    }
    function cleanup() { Language.I18n.language = "en"; }
    function test_specific_actions_and_busy_state() {
        var item = createTemporaryObject(component, test);
        tryVerify(() => item.implicitHeight > 200);
        var resume = findChild(item, "snoozeResume-first");
        var discard = findChild(item, "snoozeDiscard-second");
        verify(resume !== null && discard !== null);
        mouseClick(resume);
        compare(controller.lastCommand.action, "recover-snooze");
        compare(controller.lastCommand.args.recoveryId, "first");
        compare(controller.lastCommand.args.decision, "resume");
        mouseClick(discard);
        compare(controller.lastCommand.args.recoveryId, "second");
        compare(controller.lastCommand.args.decision, "discard");
        controller.busy = true; compare(resume.enabled, false); compare(discard.enabled, false);
        controller.busy = false; controller.ready = false; compare(resume.enabled, false);
    }
    function test_duration_localization_and_themes() {
        for (var dark of [true, false]) {
            var item = createTemporaryObject(component, test, {darkMode: dark});
            compare(item.duration(125000), "2:05");
            compare(item.duration(1), "0:01");
            compare(item.entries.length, 2);
            var resume = findChild(item, "snoozeResume-first");
            compare(resume.text, "Resume");
            Language.I18n.language = "ru";
            compare(resume.text, "Возобновить");
            Language.I18n.language = "en";
            item.destroy();
        }
    }
}

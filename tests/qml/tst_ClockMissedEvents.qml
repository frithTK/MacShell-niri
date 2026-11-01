import QtQuick
import QtTest
import "../../MacShell" as Port
import "../../MacShell/Locale" as Language

TestCase {
    id: test
    name: "ClockMissedEvents"
    when: windowShown
    width: 600; height: 500; visible: true
    QtObject {
        id: fakeBackend
        property bool ready: true
        property bool busy: false
        property var lastCommand: null
        property var timing: ({missedAlarms: [{eventId: "alarm-a", label: "Meeting"}],
                               missedSnoozes: [{id: "snooze-b", label: "Wake"}]})
        function submit(action, args) { lastCommand = {action: action, args: args}; return true; }
    }
    Component { id: component; Port.ClockMissedEvents { width: 540; backend: fakeBackend } }
    function init() { fakeBackend.ready = true; fakeBackend.busy = false; fakeBackend.lastCommand = null; Language.I18n.language = "en"; }
    function cleanup() { Language.I18n.language = "en"; }
    function test_acknowledges_the_selected_record() {
        var item = createTemporaryObject(component, test);
        tryVerify(() => item.entries.length === 2 && item.implicitHeight > 100);
        var first = findChild(item, "clockMissedDismiss-alarm-a");
        var second = findChild(item, "clockMissedDismiss-snooze-b");
        mouseClick(first);
        compare(fakeBackend.lastCommand.action, "ack-missed");
        compare(fakeBackend.lastCommand.args.kind, "alarm");
        compare(fakeBackend.lastCommand.args.eventId, "alarm-a");
        mouseClick(second);
        compare(fakeBackend.lastCommand.args.kind, "snooze");
        compare(fakeBackend.lastCommand.args.eventId, "snooze-b");
        fakeBackend.busy = true; compare(first.enabled, false);
        fakeBackend.busy = false; fakeBackend.ready = false; compare(second.enabled, false);
        Language.I18n.language = "ru"; compare(first.text, "Скрыть");
    }
}

import QtQuick
import QtTest
import "../../MacShell" as Port

TestCase {
    id: test
    name: "RemindersWidget"; when: windowShown
    width: 500; height: 500; visible: true
    Component { id: cardComponent; Port.RemindersWidget { style: "normal"; size: "medium"; preview: true; ready: true } }
    function test_preview_toggle_does_not_call_a_store() {
        var toggled = 0;
        var item = createTemporaryObject(cardComponent, test, {
            tasks: [{id: "a", title: "Try the new widgets", done: false}, {id: "b", title: "Done", done: true}]
        });
        verify(item !== null); waitForRendering(item);
        item.toggleRequested.connect(function () { toggled++; });
        compare(findChild(item, "remindersWidgetCount").text, "1");
        var tick = findChild(item, "remindersWidgetTick_a");
        verify(tick !== null);
        mouseClick(tick);
        compare(toggled, 0);
        compare(findChild(item, "remindersWidgetCount").text, "0");
        compare(item.localTasks.find(function (row) { return row.id === "a"; }).done, true);
    }
    function test_live_toggle_emits_the_task() {
        var seen = null;
        var item = createTemporaryObject(cardComponent, test, {
            preview: false, interactive: true, ready: true,
            tasks: [{id: "live", title: "Pay rent", done: 0, revision: 1}]
        });
        waitForRendering(item);
        item.toggleRequested.connect(function (task) { seen = task; });
        var tick = findChild(item, "remindersWidgetTick_live");
        verify(tick !== null);
        mouseClick(tick);
        compare(seen.id, "live");
        compare(!!seen.done, false);
    }
}

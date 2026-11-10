import QtQuick
import QtTest
import "../../MacShell" as Port

TestCase {
    id: test
    name: "NotesWidget"; when: windowShown
    width: 500; height: 500; visible: true
    Component { id: cardComponent; Port.NotesWidget { style: "normal"; size: "medium"; preview: true } }
    function test_preview_shows_store_body_and_opens_without_a_file() {
        var opened = 0;
        var item = createTemporaryObject(cardComponent, test, {
            ready: true, body: "Shopping\nMilk", notes: [{id: "n1", body: "Shopping\nMilk"}]
        });
        verify(item !== null); waitForRendering(item);
        item.openRequested.connect(function () { opened++; });
        compare(findChild(item, "notesWidgetTitle").text, "Notes");
        compare(findChild(item, "notesWidgetBody").text.indexOf("Shopping") >= 0, true);
        compare(item.interactive, false);
        item.interactive = true; waitForRendering(item);
        mouseClick(findChild(item, "notesWidgetOpen"));
        compare(opened, 1);
    }
    function test_empty_and_unavailable_states() {
        var empty = createTemporaryObject(cardComponent, test, {ready: true, body: "", notes: []});
        waitForRendering(empty);
        compare(findChild(empty, "notesWidgetBody").text, "No notes found");
        var down = createTemporaryObject(cardComponent, test, {preview: false, ready: false, body: "", notes: []});
        waitForRendering(down);
        compare(findChild(down, "notesWidgetBody").text, "Storage unavailable");
    }
}

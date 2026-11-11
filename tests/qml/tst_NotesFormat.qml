import QtQuick
import QtTest
import "../../MacShell/NotesFormat.js" as NotesFormat
import "../../MacShell" as Port

TestCase {
    id: test
    name: "NotesFormat"; when: windowShown
    width: 500; height: 500; visible: true
    Component { id: cardComponent; Port.NotesWidget { style: "normal"; size: "medium"; preview: true } }

    function test_preview_uses_excerpt_for_html_and_body_for_plain() {
        compare(NotesFormat.preview({format: "html", body: "<b>Hello</b>", excerpt: "Hello"}), "Hello")
        compare(NotesFormat.titleLine({format: "html", body: "<b>Hello</b>\nrest", excerpt: "Hello\nrest"}), "Hello")
        compare(NotesFormat.snippet({format: "plain", body: "A\nB", excerpt: "A\nB"}), "A B")
        compare(NotesFormat.matches({format: "html", body: "<script>nope</script>", excerpt: "visible"}, "visible"), true)
        compare(NotesFormat.matches({format: "html", body: "<script>nope</script>", excerpt: "visible"}, "script"), false)
        compare(NotesFormat.preview({format: "plain", body: "<b>literal</b>"}), "<b>literal</b>")
    }

    function test_widget_shows_excerpt_not_html_tags() {
        var item = createTemporaryObject(cardComponent, test, {
            ready: true, notes: [{id: "n1", format: "html", body: "<b>Shopping</b>\nMilk", excerpt: "Shopping\nMilk"}]
        });
        verify(item !== null); waitForRendering(item);
        compare(findChild(item, "notesWidgetBody").text.indexOf("Shopping") >= 0, true);
        compare(findChild(item, "notesWidgetBody").text.indexOf("<b>") >= 0, false);
    }
}

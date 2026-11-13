import QtQuick
import QtTest
import "../../MacShell/TrashItems.js" as TrashItems

TestCase {
    name: "TrashItems"

    function test_format_deleted_keeps_clock_time() {
        compare(TrashItems.formatDeleted("2024-01-02T03:04:05"), "02.01.2024 03:04")
        compare(TrashItems.formatDeleted(""), "")
        compare(TrashItems.formatDeleted("not-a-date"), "not-a-date")
    }

    function test_search_keeps_duplicate_names_distinct() {
        var items = [
            {id: "/tmp/Trash/files/a.txt", name: "notes.txt", originalPath: "/home/a/notes.txt"},
            {id: "/tmp/Trash/files/a.txt.2", name: "notes.txt", originalPath: "/home/b/notes.txt"},
            {id: "/tmp/Trash/files/pic.png", name: "фото.png", originalPath: "/home/a/фото.png"}
        ]
        compare(TrashItems.visibleItems(items, "").length, 3)
        compare(TrashItems.visibleItems(items, "notes").length, 2)
        compare(TrashItems.visibleItems(items, "/home/b").length, 1)
        compare(TrashItems.visibleItems(items, "фото").length, 1)
        compare(TrashItems.visibleItems(items, "missing").length, 0)
        compare(TrashItems.asList({0: items[0], 1: items[1], length: 2}).length, 2)
        compare(TrashItems.visibleItems({0: items[0], length: 1}, "notes").length, 1)
    }
}

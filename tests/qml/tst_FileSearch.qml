import QtQuick
import QtTest
import "../../MacShell/FileSearch.js" as FileSearch
import "../../MacShell/SettingsSearch.js" as SettingsSearch

TestCase {
    name: "FileSearch"

    function test_prefix_is_exclusive_and_stripped() {
        var prefixed = FileSearch.parse("file photo")
        compare(prefixed.exclusive, true)
        compare(prefixed.query, "photo")
        var findPrefixed = FileSearch.parse("FIND  Holiday.png")
        compare(findPrefixed.exclusive, true)
        compare(findPrefixed.query, "Holiday.png")
        var mixed = FileSearch.parse("photo")
        compare(mixed.exclusive, false)
        compare(mixed.query, "photo")
    }

    function test_short_queries_are_not_ready() {
        compare(FileSearch.ready(""), false)
        compare(FileSearch.ready("p"), false)
        compare(FileSearch.ready("ph"), true)
    }

    function test_files_keep_slots_when_apps_fill_the_list() {
        var apps = [{ title: "A" }, { title: "B" }, { title: "C" }, { title: "D" }]
        var files = [
            { title: "photo.png", kind: "file" },
            { title: "photo-2.png", kind: "file" },
            { title: "photo-3.png", kind: "file" }
        ]
        var out = []
        SettingsSearch.appendGroup(out, apps, 8, 4)
        SettingsSearch.appendGroup(out, files, 8, 3)
        compare(out.length, 7)
        compare(out[4].kind, "file")
        compare(out[6].title, "photo-3.png")
    }
}

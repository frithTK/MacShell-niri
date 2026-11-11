import QtQuick
import QtTest
import "../../MacShell/FileSearch.js" as FileSearch
import "../../MacShell/SettingsSearch.js" as SettingsSearch
import "../../MacShell/SpotlightRank.js" as Rank

TestCase {
    name: "SpotlightRank"

    readonly property var apps: [
        { id: "org.demo.notes", name: "Notes", genericName: "Editor", comment: "Write things", keywords: ["memo"] },
        { id: "org.demo.files", name: "Files", genericName: "File Manager", comment: "Browse folders", keywords: [] },
        { id: "org.demo.mail", name: "Mail", genericName: "", comment: "", keywords: ["email"] }
    ]
    readonly property var panes: [
        { id: "wifi", name: "Wi-Fi", searchName: "Wi-Fi", keys: "wireless" },
        { id: "appearance", name: "Appearance", searchName: "Appearance", keys: "theme glass" }
    ]

    function kinds(rows) { return rows.map(function (row) { return row.kind; }); }

    function test_empty_query_returns_no_apps() {
        compare(Rank.searchApps(apps, {}, ""), [])
        compare(Rank.searchApps(apps, {}, "   "), [])
        compare(Rank.assembleHome("", {}, {}), [])
        compare(Rank.assembleHome("   ", { apps: [{ kind: "app" }] }, {}), [])
    }

    function test_app_rank_prefers_exact_then_prefix() {
        var found = Rank.searchApps(apps, {}, "notes")
        compare(found[0].id, "org.demo.notes")
        found = Rank.searchApps(apps, {}, "file")
        compare(found[0].id, "org.demo.files")
        found = Rank.searchApps(apps, { "org.demo.mail": 50 }, "mail")
        compare(found[0].id, "org.demo.mail")
        found = Rank.searchApps(apps, {}, "email")
        compare(found[0].id, "org.demo.mail")
    }

    function test_file_and_find_are_exclusive() {
        compare(FileSearch.parse("file photo").exclusive, true)
        compare(FileSearch.parse("FIND Holiday.png").exclusive, true)
        var files = Rank.fileRows(["/home/me/photo.png", "/tmp/a.png", "/tmp/b.png", "/tmp/c.png"], 8)
        var out = Rank.assembleHome("file photo", { exclusive: true, files: files }, {})
        compare(out.length, 4)
        compare(kinds(out).join(), "file,file,file,file")
        out = Rank.assembleHome("file zz", { exclusive: true, files: [], filePending: true },
            { searching: "Searching…", noFiles: "No files", homeFolder: "Home" })
        compare(out.length, 1)
        compare(out[0].title, "Searching…")
        verify(out[0].kind !== "file")
    }

    function test_mixed_keeps_three_file_slots_and_settings() {
        var appsOnly = [{ title: "A", kind: "app" }, { title: "B", kind: "app" }, { title: "C", kind: "app" }, { title: "D", kind: "app" }]
        var settings = SettingsSearch.match(panes, "appearance").map(function (pane) {
            return { title: pane.name, kind: "settings", pane: pane.id }
        })
        var files = Rank.fileRows(["/a.png", "/b.png", "/c.png", "/d.png"], 8)
        var out = Rank.assembleHome("app", {
            apps: appsOnly, settings: settings, actions: [], windows: [], files: files
        }, {})
        compare(out.length, 8)
        compare(out[4].kind, "settings")
        compare(out[4].pane, "appearance")
        compare(out.filter(function (row) { return row.kind === "file"; }).length, 3)
        compare(out[7].kind, "file")
        compare(out[7].title, "c.png")
    }

    function test_calculator_and_units_skip_file_search() {
        compare(Rank.calcValue("2+2"), 4)
        compare(Rank.skipFileSearch("2+2"), true)
        compare(Rank.skipFileSearch("10 cm to in"), true)
        compare(Rank.skipFileSearch("photo"), false)
        compare(Rank.conversion("10 cm to in").to, "in")
        var calc = { title: "4", kind: "calc" }
        var out = Rank.assembleHome("2+2", { apps: [], calc: calc, files: Rank.fileRows(["/tmp/2+2.txt"], 8) }, {})
        compare(out[0].kind, "calc")
        compare(out.filter(function (row) { return row.kind === "file"; }).length, 1)
    }
}

import QtQuick
import QtTest
import "../../MacShell/SettingsSearch.js" as SettingsSearch

TestCase {
    name: "SettingsSearch"

    readonly property var panes: [
        { id: "wifi", name: "Wi-Fi", searchName: "Wi-Fi", keys: "wireless network интернет вайфай" },
        { id: "bluetooth", name: "Bluetooth", searchName: "Bluetooth", keys: "devices pair блютуз" },
        { id: "appearance", name: "Оформление", searchName: "Appearance", keys: "theme dark glass стекло" },
        { id: "dock", name: "Dock", searchName: "Dock", keys: "size icon magnification корзина" },
        { id: "battery", name: "Battery", searchName: "Battery", keys: "power charge батарея" }
    ]

    function ids(hits) {
        return hits.map(function (pane) { return pane.id; })
    }

    function test_short_and_empty_queries_are_ignored() {
        compare(SettingsSearch.match(panes, ""), [])
        compare(SettingsSearch.match(panes, "w"), [])
        compare(SettingsSearch.match(panes, "  "), [])
        compare(SettingsSearch.match([], "wifi"), [])
    }

    function test_english_and_russian_keywords_find_the_pane() {
        compare(ids(SettingsSearch.match(panes, "wifi")), ["wifi"])
        compare(ids(SettingsSearch.match(panes, "Wi-Fi")), ["wifi"])
        compare(ids(SettingsSearch.match(panes, "вайфай")), ["wifi"])
        compare(ids(SettingsSearch.match(panes, "стекло")), ["appearance"])
        compare(ids(SettingsSearch.match(panes, "Appearance")), ["appearance"])
        compare(ids(SettingsSearch.match(panes, "оформление")), ["appearance"])
        compare(ids(SettingsSearch.match(panes, "блютуз")), ["bluetooth"])
    }

    function test_exact_id_ranks_above_keyword_hits() {
        var crowded = panes.concat([{ id: "network", name: "Network", searchName: "Network", keys: "wifi ethernet" }])
        compare(ids(SettingsSearch.match(crowded, "wifi")), ["wifi", "network"])
    }

    function test_overflow_keeps_settings_when_apps_fill_the_list() {
        var apps = [{ title: "A" }, { title: "B" }, { title: "C" }, { title: "D" }]
        var settings = SettingsSearch.match(panes, "dock").map(function (pane) {
            return { title: pane.name, kind: "settings", pane: pane.id }
        })
        var out = []
        SettingsSearch.appendGroup(out, apps, 8, 4)
        SettingsSearch.appendGroup(out, settings, 8, 4)
        compare(out.length, 5)
        compare(out[4].kind, "settings")
        compare(out[4].pane, "dock")
    }

    function test_open_target_covers_disabled_missing_and_already_open() {
        var disabled = SettingsSearch.openTarget(panes, 0, "dock", false)
        compare(disabled.ok, false)
        compare(disabled.reason, "disabled")
        var missing = SettingsSearch.openTarget(panes, 0, "nope", true)
        compare(missing.ok, false)
        compare(missing.reason, "missing")
        var opened = SettingsSearch.openTarget(panes, 0, "dock", true)
        compare(opened.ok, true)
        compare(opened.index, 3)
        compare(opened.same, false)
        var again = SettingsSearch.openTarget(panes, 3, "dock", true)
        compare(again.ok, true)
        compare(again.same, true)
        compare(SettingsSearch.indexOf(panes, "battery"), 4)
    }

    function test_result_kinds_expose_only_applicable_actions() {
        compare(SettingsSearch.actionsFor("settings"), ["open"])
        compare(SettingsSearch.actionsFor("file"), ["open", "reveal", "copyPath"])
        compare(SettingsSearch.actionsFor("app"), ["open", "pin", "reveal", "info"])
        compare(SettingsSearch.actionsFor("window"), ["focus"])
        compare(SettingsSearch.actionsFor("action"), ["run"])
        verify(SettingsSearch.actionsFor("file").indexOf("run") < 0)
        compare(SettingsSearch.hasExtras("file"), true)
        compare(SettingsSearch.hasExtras("settings"), false)
        compare(SettingsSearch.extras("file"), ["reveal", "copyPath", "preview"])
        compare(SettingsSearch.extras("app"), ["pin", "reveal", "info"])
    }

    function test_local_paths_reject_injection_and_keep_unicode() {
        compare(SettingsSearch.isLocalPath("/tmp/notes.txt"), true)
        compare(SettingsSearch.isLocalPath("/tmp/файл с пробелом.txt"), true)
        compare(SettingsSearch.isLocalPath("notes.txt"), false)
        compare(SettingsSearch.isLocalPath("/tmp/bad\npath"), false)
        compare(SettingsSearch.isLocalPath(""), false)
        compare(SettingsSearch.parentDir("/home/frith/photo.png"), "/home/frith")
        compare(SettingsSearch.parentDir("/tmp/a b/c.txt"), "/tmp/a b")
        compare(SettingsSearch.parentDir("/tmp/файл.txt"), "/tmp")
        compare(SettingsSearch.parentDir("/file"), "/")
        compare(SettingsSearch.parentDir("/"), "")
        compare(SettingsSearch.parentDir("relative/path"), "")
    }

    function test_file_actions_enable_preview_for_local_paths() {
        var rows = SettingsSearch.describe("file", { path: "/tmp/Notes 1.txt" })
        compare(rows.map(function (row) { return row.id; }), ["open", "reveal", "copyPath", "preview"])
        compare(rows[0].enabled, true)
        compare(rows[1].enabled, true)
        compare(rows[2].enabled, true)
        compare(rows[2].close, false)
        compare(rows[3].enabled, true)
        compare(rows[3].close, false)
        var missing = SettingsSearch.describe("file", { path: "relative" })
        compare(missing[1].enabled, false)
        compare(missing[2].enabled, false)
        compare(missing[3].enabled, false)
        compare(missing[3].reason, "missing")
        var app = SettingsSearch.describe("app", { appId: "org.example.app" })
        compare(app.map(function (row) { return row.id; }), ["open", "pin", "reveal", "info"])
        compare(app[2].enabled, false)
        compare(app[2].reason, "unavailable")
        compare(app[3].enabled, true)
        compare(SettingsSearch.describe("settings", { pane: "wifi" }).length, 1)
    }
}

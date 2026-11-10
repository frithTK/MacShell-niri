import QtQuick
import QtTest
import "../../MacShell/AppMenuBar.js" as AppMenuBar

TestCase {
    name: "AppMenuBar"

    readonly property var labels: ({
        file: "File", edit: "Edit", view: "View", window: "Window", help: "Help"
    })

    function test_stub_titles_keep_shell_menus() {
        var rows = AppMenuBar.titles("Kitty", false, [], labels)
        compare(AppMenuBar.ids(rows), ["apple", "app", "file", "edit", "view", "window", "help"])
        compare(rows[1].label, "Kitty")
        compare(rows[1].bold, true)
        verify(AppMenuBar.isMenuId("file"))
        verify(!AppMenuBar.isMenuId("cc"))
    }

    function test_exported_titles_replace_stubs() {
        var menus = [
            {id: "d:10", label: "File"},
            {id: "d:11", label: "Edit"}
        ]
        var rows = AppMenuBar.titles("GEdit", true, menus, labels)
        compare(AppMenuBar.ids(rows), ["apple", "app", "appmenu:d:10", "appmenu:d:11"])
        compare(AppMenuBar.menuKey("appmenu:d:10"), "d:10")
        compare(AppMenuBar.popupType("appmenu:d:11"), "appMenus")
        compare(AppMenuBar.findMenu(menus, "d:11").label, "Edit")
        verify(AppMenuBar.isMenuId("appmenu:d:10"))
    }
}

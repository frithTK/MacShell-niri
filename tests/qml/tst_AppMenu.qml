import QtQuick
import QtTest
import "../../MacShell/AppMenu.js" as AppMenu

TestCase {
    name: "AppMenu"

    function ids(rows) {
        return AppMenu.ids(rows)
    }

    function test_shared_rows_cover_pin_reveal_and_info() {
        var pending = AppMenu.actions({ pinned: false, hasEntry: true, source: null })
        compare(ids(pending), ["open", "pin", "reveal", "info"])
        compare(pending[1].pinned, false)
        compare(pending[2].enabled, false)
        compare(pending[2].reason, "pending")
        compare(pending[3].enabled, false)
        compare(pending[3].reason, "pending")
        var pinned = AppMenu.actions({ pinned: true, hasEntry: true, source: { origin: "local", unique: true, path: "/tmp/apps/foo.desktop" } })
        compare(pinned[1].pinned, true)
        compare(pinned[2].enabled, true)
        compare(pinned[3].enabled, true)
        compare(pinned.length, 4)
    }

    function test_builtin_and_ambiguous_sources_do_not_offer_packages() {
        var builtin = AppMenu.actions({ pinned: true, hasEntry: true, source: { origin: "builtin", unique: true } })
        compare(ids(builtin).indexOf("remove") < 0, true)
        compare(builtin[2].enabled, false)
        compare(builtin[2].reason, "builtin")
        var clash = AppMenu.actions({ source: { origin: "ambiguous", unique: false } })
        compare(ids(clash).indexOf("remove") < 0, true)
        compare(clash[2].reason, "ambiguous")
    }

    function test_official_pacman_requires_explicit_confirmation() {
        var source = {
            origin: "pacman",
            unique: true,
            official: true,
            path: "/usr/share/applications/org.kde.dolphin.desktop",
            package: "dolphin",
            repo: "extra",
            version: "24.12.3-1",
            operations: { remove: true, reinstall: false, update: true, reasons: { remove: "confirm", reinstall: "system-update", update: "confirm" } }
        }
        var rows = AppMenu.actions({ pinned: false, hasEntry: true, source: source })
        compare(ids(rows), ["open", "pin", "reveal", "info", "sep", "remove", "update"])
        compare(rows[5].enabled, true)
        compare(rows[5].confirm, true)
        compare(rows[5].confirmKind, "remove")
        compare(rows[5].summary, "dolphin · extra · 24.12.3-1")
        compare(rows[6].enabled, true)
        compare(rows[6].confirm, true)
        compare(rows[6].confirmKind, "update_system")
        var busy = AppMenu.actions({ source: source, applying: true })
        compare(busy[5].enabled, false)
        compare(busy[5].reason, "busy")
        compare(busy[6].enabled, false)
    }

    function test_unofficial_pacman_is_not_an_update_target() {
        var source = {
            origin: "pacman",
            unique: true,
            official: false,
            path: "/usr/share/applications/example.desktop",
            operations: { remove: true, reinstall: false, update: false, reasons: { remove: "unofficial", reinstall: "unofficial", update: "unofficial" } }
        }
        var rows = AppMenu.actions({ source: source })
        compare(ids(rows), ["open", "pin", "reveal", "info", "sep", "remove"])
        compare(rows[5].enabled, false)
        compare(rows[5].reason, "unofficial")
        compare(rows[5].confirm, false)
    }

    function test_flatpak_reinstall_is_offered_with_confirmation() {
        var source = {
            origin: "flatpak-user",
            unique: true,
            official: true,
            path: "/home/u/.local/share/flatpak/exports/share/applications/org.example.App.desktop",
            flatpakId: "org.example.App",
            operations: { remove: true, reinstall: true, update: true, reasons: { remove: "confirm", reinstall: "confirm", update: "confirm" } }
        }
        var rows = AppMenu.actions({ source: source })
        compare(ids(rows), ["open", "pin", "reveal", "info", "sep", "remove", "reinstall", "update"])
        compare(rows[5].enabled, true)
        compare(rows[5].confirm, true)
        compare(rows[6].enabled, true)
        compare(rows[6].confirmKind, "reinstall")
        compare(rows[7].enabled, true)
        compare(rows[7].confirmKind, "update")
        compare(rows[5].summary.indexOf("user") >= 0, true)
    }
}

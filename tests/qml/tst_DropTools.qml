import QtQuick
import QtTest
import "../../MacShell/DropTools.js" as DropTools
import "../../MacShell/SettingsSearch.js" as SettingsSearch

TestCase {
    name: "DropTools"

    function test_uri_list_keeps_local_files_and_drops_injection() {
        var paths = DropTools.parseUriList("file:///tmp/Notes%201.png\r\n/tmp/файл.jpg\nhttps://example/a.png\nnotes.txt")
        compare(paths, ["/tmp/Notes 1.png", "/tmp/файл.jpg"])
        compare(DropTools.localPaths(["file:///tmp/a.png", "file:///tmp/a.png", "relative"]), ["/tmp/a.png"])
        compare(DropTools.parseUriList(""), [])
    }

    function test_common_actions_require_every_file() {
        var png = { actions: [{ id: "png", available: true }, { id: "jpeg", available: true }, { id: "pdf", available: true }] }
        var jpeg = { actions: [{ id: "png", available: true }, { id: "jpeg", available: true }] }
        var pdf = { actions: [{ id: "pdf-png", available: true }, { id: "pdf-jpeg", available: false, missing: "pdftoppm" }] }
        compare(DropTools.commonActions([png, jpeg]).map(function (row) { return row.id }), ["png", "jpeg"])
        compare(DropTools.commonActions([png, pdf]), [])
        compare(DropTools.commonActions([pdf]).map(function (row) { return row.id }), ["pdf-png"])
        compare(DropTools.commonActions([]), [])
    }

    function test_keyboard_wraps_and_skips_unavailable() {
        var actions = [
            { id: "png", available: true },
            { id: "jpeg", available: false },
            { id: "pdf", available: true }
        ]
        compare(DropTools.firstAvailable(actions), 0)
        compare(DropTools.nextIndex(actions, 0, 1), 2)
        compare(DropTools.nextIndex(actions, 2, 1), 0)
        compare(DropTools.nextIndex(actions, 0, -1), 2)
        compare(DropTools.nextIndex([], 0, 1), 0)
    }

    function test_result_summary_and_error_keys() {
        compare(DropTools.resultKey({ cancelled: true, ok: 0, failed: 1 }), "droptools.cancelled")
        compare(DropTools.resultKey({ partial: true, ok: 1, failed: 1 }), "droptools.partial")
        compare(DropTools.resultKey({ ok: 2, failed: 0 }), "droptools.done")
        compare(DropTools.resultKey({ ok: 0, failed: 1 }), "droptools.failed")
        compare(DropTools.dests([{ success: true, dest: "/tmp/a-png.png" }, { success: false, dest: "" }]), ["/tmp/a-png.png"])
        compare(DropTools.errorKey("pdftoppm"), "droptools.missing_pdftoppm")
        compare(DropTools.errorKey("decode"), "droptools.decode")
        compare(DropTools.actionKey("pdf-png"), "droptools.pdf_png")
        verify(SettingsSearch.isLocalPath("/tmp/a.png"))
    }
}

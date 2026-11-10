import QtQuick
import QtTest
import "../../MacShell/StorageState.js" as State

TestCase {
    name: "Storage"
    function test_format_bytes() {
        compare(State.formatBytes(-1), "");
        compare(State.formatBytes(512), "512 B");
        compare(State.formatBytes(1024), "1.0 KiB");
        compare(State.formatBytes(10 * 1024), "10 KiB");
        compare(State.formatBytes(1024 * 1024), "1.0 MiB");
    }
    function test_used_ratio_and_unavailable() {
        compare(State.usedRatio(40, 100), 0.4);
        compare(State.usedRatio(0, 0), 0);
        compare(State.volumeLine({ready: false}), "Unavailable");
        compare(State.volumeLine({ready: true, used: 1024, total: 2048, available: 1024}), "1.0 KiB of 2.0 KiB (1.0 KiB free)");
    }
    function test_folder_listing_is_not_volume_used() {
        var folders = [{bytes: 100}, {bytes: 40}];
        verify(State.foldersAreNotVolume(folders, {used: 8000}));
        compare(State.foldersAreNotVolume([{bytes: 50}], {used: 50}), false);
    }
    function test_scan_notes_do_not_claim_a_full_map() {
        verify(State.scanNote({incomplete: true, reason: "limit"}).indexOf("not a full disk map") >= 0);
        verify(State.scanNote({cancelled: true}).indexOf("cancelled") >= 0);
        compare(State.folderTitle("documents", "Documents"), "Documents");
    }
}

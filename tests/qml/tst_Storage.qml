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
        compare(State.volumeLine({ready: true, used: 1024, total: 2048, available: 1024}), "1.0 KiB of 2.0 KiB · 50% · 1.0 KiB free");
    }
    function test_primary_volumes_hide_same_disk_binds() {
        var rows = State.primaryVolumes([
            {path: "/", bind: false, name: "System"},
            {path: "/home", bind: true, name: "Home"},
            {path: "/boot/efi", bind: false, name: "EFI"}
        ]);
        compare(rows.length, 2);
        compare(rows[0].path, "/");
        compare(rows[1].path, "/boot/efi");
        compare(State.volumeTitle({path: "/", name: "System"}), "System");
        compare(State.volumeTitle({path: "/boot/efi", name: "EFI"}), "EFI");
    }
    function test_status_does_not_claim_empty_while_loading() {
        compare(State.statusText({loading: true, ready: false, volumes: [], measuredAt: 0}), "Reading volume sizes…");
        compare(State.statusText({loading: false, ready: true, volumes: [], helperError: ""}), "");
        compare(State.statusText({loading: true, scanned: true, volumes: []}), "");
        compare(State.statusText({loading: true, ready: true, volumes: [{path: "/", bind: false}], measuredAt: 0}), "");
        verify(State.statusText({loading: false, ready: false, volumes: [], helperError: "missing"}).indexOf("missing") >= 0);
    }
    function test_as_list_copies_array_like_payloads() {
        var copied = State.asList({0: {path: "/"}, 1: {path: "/boot/efi"}, length: 2});
        compare(copied.length, 2);
        compare(copied[0].path, "/");
        compare(State.asList(null).length, 0);
        compare(State.primaryVolumes({0: {path: "/", bind: false}, 1: {path: "/home", bind: true}, length: 2}).length, 1);
    }
    function test_folder_listing_is_not_volume_used() {
        var folders = [{bytes: 100}, {bytes: 40}];
        verify(State.foldersAreNotVolume(folders, {used: 8000}));
        compare(State.foldersAreNotVolume([{bytes: 50}], {used: 50}), false);
    }
    function test_category_bar_fills_used_space() {
        var volume = {path: "/", ready: true, used: 1000, total: 2000};
        compare(State.volumeCategories(volume, {scanned: false}).length, 0);
        var rows = State.volumeCategories(volume, {
            scanned: true,
            folders: [
                {id: "pictures", bytes: 100},
                {id: "videos", bytes: 50},
                {id: "documents", bytes: 80}
            ],
            apps: [{bytes: 200}],
            trash: {bytes: 20}
        });
        var byId = {};
        var used = 0;
        for (var i = 0; i < rows.length; i++) {
            byId[rows[i].id] = rows[i];
            used += rows[i].bytes;
        }
        compare(byId.apps.bytes, 200);
        compare(byId.photos.bytes, 100);
        compare(byId.videos.bytes, 50);
        compare(byId.documents.bytes, 80);
        compare(byId.trash.bytes, 20);
        compare(byId.system.bytes, 550);
        compare(used, 1000);
        compare(Math.round(byId.system.ratio * 2000), 550);
        compare(State.categoryHostPath([{path: "/", bind: false}, {path: "/boot/efi", bind: false}], "/home/frith"), "/");
        compare(State.categoryHostPath([{path: "/", bind: false}, {path: "/home", bind: false}], "/home/frith"), "/home");
        var scaled = State.volumeCategories({path: "/", ready: true, used: 100, total: 400}, {
            scanned: true,
            folders: [{id: "pictures", bytes: 80}],
            apps: [{bytes: 80}],
            trash: {bytes: 40}
        });
        var scaledSum = 0;
        for (var s = 0; s < scaled.length; s++) scaledSum += scaled[s].bytes;
        compare(scaledSum, 100);
        compare(State.categoryTitle("photos"), "Photos");
        compare(State.categoryTitle("trash"), "Trash");
        compare(State.trashLine({bytes: "2048"}, false), "2.0 KiB");
        compare(State.trashPreview([{name: "a"}, {name: "b"}, {name: "c"}], 2).length, 2);
    }
    function test_scan_notes_do_not_claim_a_full_map() {
        verify(State.scanNote({incomplete: true, reason: "limit"}).indexOf("not a full disk map") >= 0);
        verify(State.scanNote({cancelled: true}).indexOf("cancelled") >= 0);
        compare(State.scanNote({scanned: false}), "");
        compare(State.folderTitle("documents", "Documents"), "Documents");
        compare(State.trashLine({}, false), "Scan to measure");
        compare(State.trashLine({bytes: 2048}, false), "2.0 KiB");
    }
}

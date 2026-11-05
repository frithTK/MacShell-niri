Timer {
    interval: 150; repeat: true
    running: cell.modelData.special === "trash"
    property int step: 0
    property int waits: 0
    onTriggered: {
        if (++waits > 100) { console.error("DOCK_TRASH_FAIL timeout step=" + step); Qt.exit(1); return; }
        if (!root.trashReady || cell.width < 1 || img.status !== Image.Ready) return;
        if (step === 0 && !root.trashFull && img.source.toString().endsWith("dock-trash-empty.svg")) {
            if (!ma.visible || !root.menuFor(cell.modelData).length) { console.error("DOCK_TRASH_FAIL controls"); Qt.exit(1); return; }
            var captureEmpty = Quickshell.env("MACSHELL_TRASH_CAPTURE_DIR");
            if (captureEmpty) cell.grabToImage(result => result.saveToFile(captureEmpty + "/macshell-trash-empty.png"), Qt.size(256, 256));
            step = 1;
            console.log("DOCK_TRASH_EMPTY_READY");
        } else if (step === 1 && waits > 20) {
            root.trashFull = true; step = 2;
        } else if (step === 2 && root.trashFull && img.source.toString().endsWith("dock-trash-full.svg")) {
            var captureFull = Quickshell.env("MACSHELL_TRASH_CAPTURE_DIR");
            if (captureFull) cell.grabToImage(result => result.saveToFile(captureFull + "/macshell-trash-full.png"), Qt.size(256, 256));
            step = 3;
            console.log("DOCK_TRASH_FULL_READY");
        } else if (step === 3 && waits > 40) {
            root.trashFull = false; step = 4;
        } else if (step === 4 && !root.trashFull && img.source.toString().endsWith("dock-trash-empty.svg")) {
            console.log("DOCK_TRASH_PASS: actual Dock images loaded, empty/full transition and controls"); Qt.quit();
        }
    }
}

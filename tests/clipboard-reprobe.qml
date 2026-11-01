property int clipboardPhase: 0
property int clipboardWaits: 0
Process {
    id: installClipboardFixture
    command: ["ln", "-s", Quickshell.env("MACSHELL_TEST_CLIPHIST"), Quickshell.env("MACSHELL_TEST_CLIPHIST_LINK")]
    onExited: (code, status) => {
        if (code !== 0) { console.error("MACSHELL_CLIPBOARD_REPROBE_FAIL: fixture installation"); Qt.exit(1); return; }
        clipboardPhase = 2;
        macBar.spotOpen("clip");
    }
}
Timer {
    running: true; repeat: true; interval: 150
    onTriggered: {
        if (++clipboardWaits > 100) { console.error("MACSHELL_CLIPBOARD_REPROBE_FAIL: timeout", clipboardPhase, macBar.clipState); Qt.exit(1); return; }
        if (!macBar.settingsReady) return;
        if (clipboardPhase === 0 && macBar.clipState === "missing") {
            clipboardPhase = 1;
            installClipboardFixture.running = true;
        } else if (clipboardPhase === 2 && macBar.clipState === "ok" && !macBar.clipLoading) {
            console.log("MACSHELL_CLIPBOARD_REPROBE_PASS: missing dependency detected after opening clipboard"); Qt.quit();
        }
    }
}

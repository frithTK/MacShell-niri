property int updatesTestPhase: 0
property int updatesTestWaits: 0
property var updatesTestPane: null
property bool updatesTestSaving: false
Item {
    parent: macDock.testWindow().contentItem
    TestEvent { id: updatesTestEvents }
}
function updatesTestFind(item, name) {
    if (!item) return null;
    if (item.objectName === name) return item;
    for (var child of item.children || []) { var found = updatesTestFind(child, name); if (found) return found; }
    return null;
}
function updatesTestCheck(value, reason) { if (!value) throw new Error("UPDATES_NATIVE_FAIL " + reason); }
function updatesTestCapture(name) {
    var directory = Quickshell.env("MACSHELL_UPDATES_CAPTURE");
    if (!directory) return;
    updatesTestSaving = true;
    macDock.testWindow().contentItem.grabToImage(result => {
        updatesTestCheck(result.saveToFile(directory + "/" + name + ".png"), "capture");
        updatesTestSaving = false;
    });
}
Timer {
    interval: 350; repeat: true; running: true
    onTriggered: {
        try {
            if (++updatesTestWaits > 100) throw new Error("timeout");
            if (!macBar.settingsReady || !macDock.settingsReady || updatesTestSaving) return;
            var win = macDock.testWindow();
            if (updatesTestPhase === 0) {
                sharedHub.translations.language = "ru";
                macDock.darkMode = true; macDock.openPrefs("updates");
            } else if (updatesTestPhase === 1) {
                updatesTestPane = updatesTestFind(win.contentItem, "settingsUpdates");
                if (!updatesTestPane || updatesTestPane.busy || !updatesTestPane.release.state) return;
                updatesTestCheck(updatesTestPane.release.state === "available", "release available");
                updatesTestCheck(updatesTestPane.packages.count === 2, "package count");
                updatesTestCheck(win.panes.find(p => p.id === "updates").name === "Обновления", "translated sidebar");
                updatesTestCapture("updates-dark");
            } else if (updatesTestPhase === 2) {
                var prepare = updatesTestFind(win.contentItem, "updatesPrepare");
                updatesTestCheck(prepare && prepare.visible && prepare.enabled, "prepare button");
                updatesTestEvents.mouseClick(prepare, prepare.width / 2, prepare.height / 2, Qt.LeftButton, Qt.NoModifier, 0);
            } else if (updatesTestPhase === 3) {
                if (updatesTestPane.busy || !updatesTestPane.prepared) return;
                updatesTestCheck(updatesTestPane.prepared.tag === "v1.2.0", "prepared version");
                updatesTestCheck(updatesTestPane.prepared.command.indexOf("install.sh") >= 0, "install command");
                macDock.darkMode = false;
            } else if (updatesTestPhase === 4) {
                updatesTestCapture("updates-light");
            } else if (updatesTestPhase === 5) {
                var install = updatesTestFind(win.contentItem, "updatesInstallPackages");
                updatesTestCheck(install && install.visible && install.enabled, "system button");
                install.clicked();
            } else if (updatesTestPhase === 6) {
                if (updatesTestPane.busy || updatesTestPane.notice === "") return;
                updatesTestCheck(updatesTestPane.notice.indexOf("терминале") >= 0, "system update result");
                console.log("MACSHELL_UPDATES_NATIVE_PASS: both themes, real Settings pane, prepare and package actions with isolated backend");
                Qt.quit(); return;
            }
            updatesTestPhase++;
        } catch (error) { console.error("UPDATES_NATIVE_FAIL", error); Qt.exit(1); }
    }
}

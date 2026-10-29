property int biometricPhase: 0
property int biometricWaits: 0
property bool biometricSaving: false
Item { parent: macDock.testWindow().contentItem; TestEvent { id: biometricEvents } }
function biometricFind(item, name) {
    if (!item) return null;
    if (item.objectName === name) return item;
    for (var child of item.children || []) { var result = biometricFind(child, name); if (result) return result; }
    return null;
}
function biometricCheck(value, message) { if (!value) throw new Error("BIOMETRIC_NATIVE_FAIL: " + message); }
function biometricClick(name) {
    var item = biometricFind(macDock.testWindow().contentItem, name);
    biometricCheck(item && item.visible && item.enabled, "interactive " + name);
    biometricEvents.mouseClick(item, item.width / 2, item.height / 2, Qt.LeftButton, Qt.NoModifier, 0);
}
function biometricCapture(name) {
    var directory = Quickshell.env("MACSHELL_BIOMETRIC_CAPTURE");
    if (!directory) return;
    biometricSaving = true;
    macDock.testWindow().contentItem.grabToImage(result => {
        biometricCheck(result.saveToFile(directory + "/" + name + ".png"), "capture");
        biometricSaving = false;
    });
}
Timer {
    interval: 300; running: true; repeat: true
    onTriggered: {
        try {
            if (++biometricWaits > 80) throw new Error("timeout");
            if (!macBar.settingsReady || !macDock.settingsReady || biometricSaving) return;
            var win = macDock.testWindow();
            if (biometricPhase === 0) {
                sharedHub.translations.language = "ru";
                macDock.darkMode = true;
                macDock.openPrefs("security"); win.raise(); win.requestActivate();
            } else if (biometricPhase === 1) {
                var pane = biometricFind(win.contentItem, "biometricSettings");
                if (!pane || pane.status === "checking") return;
                biometricCheck(pane.status === "ok", "fixture sensor not found");
                var device = biometricFind(win.contentItem, "biometricDeviceName");
                var enrollment = biometricFind(win.contentItem, "biometricEnrollment");
                biometricCheck(device && device.text === "Demo fingerprint reader", "device name");
                biometricCheck(enrollment && enrollment.text === "Зарегистрировано пальцев: 2", "Russian enrollment count");
                var choice = biometricFind(win.contentItem, "fingerSelection");
                biometricCheck(choice && choice.contentItem.text === "Правый указательный" && pane.selectedFinger === "right-index-finger", "visible choice agrees with operation finger");
                biometricCapture("biometric-ru-dark");
            } else if (biometricPhase === 2) {
                macDock.darkMode = false;
            } else if (biometricPhase === 3) {
                biometricCapture("biometric-ru-light");
            } else if (biometricPhase === 4) {
                sharedHub.translations.language = "en";
            } else if (biometricPhase === 5) {
                var enrollmentEn = biometricFind(win.contentItem, "biometricEnrollment");
                biometricCheck(enrollmentEn && enrollmentEn.text === "Registered fingers: 2", "English enrollment count");
                var selection = biometricFind(win.contentItem, "fingerSelection");
                var selectedPane = biometricFind(win.contentItem, "biometricSettings");
                biometricCheck(selection.contentItem.text === "Right index finger", "translated selected finger");
                selection.currentIndex = 0;
                biometricCheck(selectedPane.selectedFinger === "left-thumb" && selection.contentItem.text === "Left thumb ✓", "registered selection is consistent");
                biometricCheck(!biometricFind(win.contentItem, "fingerAdd").enabled && biometricFind(win.contentItem, "fingerTest").enabled, "registered finger actions");
                selection.currentIndex = 6;
                biometricClick("fingerAdd");
            } else if (biometricPhase === 6) {
                var warning = biometricFind(win.contentItem, "fingerConfirmation");
                biometricCheck(warning && warning.visible && warning.text.indexOf("other-system") >= 0, "enrollment warning");
                biometricClick("fingerConfirm");
            } else if (biometricPhase === 7) {
                var pane1 = biometricFind(win.contentItem, "biometricSettings");
                if (!pane1 || pane1.operationCode !== "enroll-completed" || pane1.status !== "ok" || !pane1.selectedEnrolled) return;
                biometricCheck(biometricFind(win.contentItem, "fingerSelection").contentItem.text === "Right index finger ✓", "selected finger remains correct after refresh");
                biometricClick("fingerTest");
            } else if (biometricPhase === 8) {
                var pane2 = biometricFind(win.contentItem, "biometricSettings");
                if (!pane2 || pane2.operationCode !== "verify-match" || pane2.status !== "ok") return;
                biometricClick("fingerTest");
            } else if (biometricPhase === 9) {
                var paneCancel = biometricFind(win.contentItem, "biometricSettings");
                if (!paneCancel || paneCancel.operationCode !== "scan") return;
                biometricClick("fingerCancel");
            } else if (biometricPhase === 10) {
                var cancelledPane = biometricFind(win.contentItem, "biometricSettings");
                if (!cancelledPane || cancelledPane.operationCode !== "cancelled" || cancelledPane.status !== "ok") return;
                biometricClick("fingerDelete");
            } else if (biometricPhase === 11) {
                var warningDelete = biometricFind(win.contentItem, "fingerConfirmation");
                biometricCheck(warningDelete && warningDelete.visible && warningDelete.text.indexOf("Delete") >= 0, "delete confirmation");
                biometricClick("fingerConfirm");
            } else if (biometricPhase === 12) {
                var pane3 = biometricFind(win.contentItem, "biometricSettings");
                if (!pane3 || pane3.operationCode !== "deleted" || pane3.status !== "ok" || pane3.selectedEnrolled) return;
                win.hide();
                console.log("MACSHELL_BIOMETRIC_NATIVE_PASS: fixture sensor, RU/EN, themes, enrollment warning, verify, cancel and selected delete");
                Qt.quit(); return;
            }
            biometricPhase++;
        } catch (error) { console.error(error); Qt.exit(1); }
    }
}

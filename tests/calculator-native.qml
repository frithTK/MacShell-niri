// Injected into the full shell; all preferences and service inputs are isolated.
property int calculatorPhase: 0
property int calculatorWaits: 0
property int calculatorShot: 0
property bool calculatorSaving: false
Item {
    parent: calculatorApp.window.contentItem
    TestEvent { id: calculatorEvents }
    Image { id: calculatorCatalogIcon; source: macBar.iconSrc(macBar.searchApps("Calculator")[0].icon) }
    Image { id: clockCatalogIcon; source: macBar.iconSrc(macBar.searchApps("Clock")[0].icon) }
    Image { id: calculatorDockIcon; source: macDock.iconSrc(macDock.lookup("macshell-calculator").icon) }
    Image { id: clockDockIcon; source: macDock.iconSrc(macDock.lookup("macshell-clock").icon) }
}
function calculatorCheck(value, reason) { if (!value) throw new Error("CALCULATOR_FAIL phase " + calculatorPhase + ": " + reason); }
function calculatorFind(item, name) {
    if (!item) return null;
    if (item.objectName === name) return item;
    for (var child of item.children || []) { var found = calculatorFind(child, name); if (found) return found; }
    return null;
}
function calculatorClick(name) {
    var item = calculatorFind(calculatorApp.window.contentItem, name);
    calculatorCheck(item && item.visible && item.enabled, "interactive " + name);
    calculatorEvents.mouseClick(item, item.width / 2, item.height / 2, Qt.LeftButton, Qt.NoModifier, 0);
}
Timer {
    interval: 220; repeat: true; running: true
    onTriggered: {
        if (++calculatorWaits > 180) { console.error("CALCULATOR_FAIL timeout phase " + calculatorPhase); Qt.exit(1); return; }
        if (!macBar.settingsReady || !macDock.settingsReady || !macWidgets.ready || calculatorSaving) return;
        try {
            var state = calculatorApp.state, win = calculatorApp.window;
            if (calculatorPhase === 0) {
                calculatorCheck(!win.visible && !calculatorFind(win.contentItem, "calculatorExpression"), "closed UI is unloaded");
                var hit = macBar.searchApps("калькулятор").find(app => app.id === "macshell-calculator");
                calculatorCheck(hit && macBar.searchApps("будильник").some(app => app.id === "macshell-clock"), "Russian search entries");
                calculatorCheck(macBar.appList.filter(app => app.id === "macshell-calculator").length === 1, "one catalog entry");
                calculatorCheck(calculatorCatalogIcon.status === Image.Ready && clockCatalogIcon.status === Image.Ready &&
                    calculatorDockIcon.status === Image.Ready && clockDockIcon.status === Image.Ready, "builtin icons load in catalog and Dock without a theme");
                macBar.launchApp(hit);
            } else if (calculatorPhase === 1) {
                calculatorCheck(win.visible && calculatorFind(win.contentItem, "calculatorExpression"), "search opens Calculator");
                for (var key of ["2", "4", "+", "6", "="]) calculatorClick("calculatorKey_" + key);
                calculatorCheck(state.result === "30", "real buttons");
                var input = calculatorFind(win.contentItem, "calculatorExpression");
                input.forceActiveFocus(); input.selectAll();
                calculatorEvents.keyClick(Qt.Key_8, Qt.NoModifier, 0);
                calculatorEvents.keyClick(Qt.Key_Asterisk, Qt.NoModifier, 0);
                calculatorEvents.keyClick(Qt.Key_9, Qt.NoModifier, 0);
                calculatorEvents.keyClick(Qt.Key_Return, Qt.NoModifier, 0);
                calculatorCheck(state.result === "72", "native keyboard: " + state.expression + " = " + state.result);
                win.hide();
            } else if (calculatorPhase === 2) {
                calculatorCheck(!calculatorFind(win.contentItem, "calculatorExpression") && state.result === "72", "close releases UI and retains session");
                var entry = macDock.lookup("macshell-calculator.desktop");
                calculatorCheck(entry && typeof entry.execute === "function", "Dock resolves builtin");
                macDock.togglePin({key: entry.id, entry: entry});
                calculatorCheck(macDock.pinned.indexOf(entry.id) >= 0 && macDock.items.some(item => item.key === entry.id && item.pinned), "builtin can be pinned");
                macDock.togglePin({key: entry.id, entry: entry});
                calculatorCheck(macDock.pinned.indexOf(entry.id) < 0, "builtin can be unpinned");
                macDock.activate({kind: "app", key: entry.id, appId: entry.id, entry: entry}, false);
            } else if (calculatorPhase === 3) {
                calculatorCheck(win.visible && state.result === "72", "Dock reopens retained state");
                calculatorCheck(macDock.appOf({appId: "org.quickshell", title: "Clock"}) === "macshell-clock", "Clock has separate identity");
                calculatorCheck(macDock.appOf({appId: "org.quickshell", title: "Calculator"}) === "macshell-calculator", "Calculator has separate identity");
                win.hide(); macBar.launchApp(macBar.searchApps("Clock").find(app => app.id === "macshell-clock"));
            } else if (calculatorPhase >= 4 && calculatorPhase <= 7) {
                var index = calculatorPhase - 4;
                clockApp.open(["world", "alarms", "stopwatch", "timers"][index]);
                calculatorCheck(clockApp.testWindow().visible && clockApp.testWindow().tab === index, "Clock section " + index);
                if (index === 3) { clockApp.testWindow().hide(); calculatorApp.open(); }
            } else if (calculatorPhase === 8) {
                var modes = ["basic", "scientific", "convert"], mode = modes[calculatorShot % 3], dark = calculatorShot < 3;
                macDock.darkMode = dark; macBar.darkMode = dark;
                state.historyOpen = false; state.clear(); state.mode = mode;
                if (mode === "convert") { state.changeGroup("temperature"); state.from = "C"; state.to = "F"; state.expression = "100"; }
                else state.expression = mode === "scientific" ? "sin(30)^2+cos(30)^2" : "(24+6)*3";
                state.compute();
            } else if (calculatorPhase === 9) {
                var directory = Quickshell.env("MACSHELL_CALCULATOR_CAPTURE"), mode = state.mode, theme = calculatorShot < 3 ? "dark" : "light";
                calculatorCheck(calculatorFind(win.contentItem, "calculatorExpression").width > 300, "usable expression width");
                if (directory) {
                    calculatorSaving = true;
                    win.contentItem.grabToImage(result => {
                        if (!result.saveToFile(directory + "/calculator-" + mode + "-" + theme + ".png")) { console.error("CALCULATOR_FAIL screenshot"); Qt.exit(1); }
                        calculatorSaving = false;
                    });
                }
                if (++calculatorShot < 6) { calculatorPhase = 8; return; }
            } else if (calculatorPhase === 10) {
                win.hide();
            } else if (calculatorPhase === 11) {
                calculatorCheck(!calculatorFind(win.contentItem, "calculatorExpression"), "final UI released");
                console.log("MACSHELL_CALCULATOR_PASS: native buttons/keyboard, Russian catalog search, Dock launch, separate window identities, close/reopen, all Clock sections and three modes in two themes");
                Qt.quit(); return;
            }
            calculatorPhase++;
        } catch (error) { console.error(error); Qt.exit(1); }
    }
}

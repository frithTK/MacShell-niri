property int systemLanguagePhase: 0
property int systemLanguageWaits: 0
property var systemLanguagePane: null
property string systemLanguageCalculator: ""
property bool systemLanguageSaving: false
Item {
    parent: macDock.testWindow().contentItem
    TestEvent { id: systemLanguageEvents }
}
function systemLanguageFind(item, name) {
    if (!item) return null;
    if (item.objectName === name) return item;
    for (var child of item.children || []) { var found = systemLanguageFind(child, name); if (found) return found; }
    return null;
}
function systemLanguageCheck(value, reason) { if (!value) throw new Error("SYSTEM_LANGUAGE_NATIVE_FAIL phase " + systemLanguagePhase + ": " + reason); }
function systemLanguageClick(name) {
    var item = systemLanguageFind(macDock.testWindow().contentItem, name);
    systemLanguageCheck(item && item.visible && item.enabled, "interactive " + name);
    systemLanguageEvents.mouseClick(item, item.width / 2, item.height / 2, Qt.LeftButton, Qt.NoModifier, 0);
}
function systemLanguageCapture(name) {
    var directory = Quickshell.env("MACSHELL_TRANSLATION_CAPTURE");
    if (!directory) return;
    systemLanguageSaving = true;
    macDock.testWindow().contentItem.grabToImage(result => {
        systemLanguageCheck(result.saveToFile(directory + "/" + name + ".png"), "save " + name);
        systemLanguageSaving = false;
    });
}
Timer {
    interval: 350; repeat: true; running: true
    onTriggered: {
        try {
            if (++systemLanguageWaits > 150) throw new Error("startup timeout");
            if (!macBar.settingsReady || !macDock.settingsReady || systemLanguageSaving) return;
            var win = macDock.testWindow(), i18n = sharedHub.translations;
            if (Quickshell.env("MACSHELL_LANGUAGE_RESTART") === "1") {
                if (i18n.activeLanguage !== "ru") return;
                systemLanguageCheck(i18n.formatLocale.name.startsWith("ru"), "new process inherits Russian locale");
                console.log("MACSHELL_SYSTEM_LANGUAGE_RESTART_PASS: persisted desktop language and process locale");
                Qt.quit(); return;
            }
            if (systemLanguagePhase === 0) {
                macDock.openPrefs("language"); calculatorApp.open("12.5+7.5");
                systemLanguageCalculator = JSON.stringify(calculatorApp.state.history);
                win.raise(); win.requestActivate();
            } else if (systemLanguagePhase === 1) {
                systemLanguagePane = systemLanguageFind(win.contentItem, "languageSettings");
                if (!systemLanguagePane || !systemLanguagePane.controller.ready) return;
                systemLanguageCheck(systemLanguagePane.controller.errorCode === "", "locale service ready");
                systemLanguageClick("systemLanguage");
            } else if (systemLanguagePhase === 2) {
                var combo = systemLanguageFind(win.contentItem, "systemLanguage"), option = combo.popup.contentItem.itemAtIndex(1);
                systemLanguageCheck(option && option.visible, "Russian menu option");
                systemLanguageEvents.mouseClick(option, option.width / 2, option.height / 2, Qt.LeftButton, Qt.NoModifier, 0);
            } else if (systemLanguagePhase === 3) {
                systemLanguageCheck(systemLanguagePane.draft.ui === "ru" && systemLanguagePane.draft.session.startsWith("ru_"), "system choice selects UI and application language: " + JSON.stringify(systemLanguagePane.draft));
                systemLanguageClick("languageApply");
            } else if (systemLanguagePhase === 4) {
                if (systemLanguagePane.controller.pending) return;
                systemLanguageCheck(systemLanguagePane.controller.errorCode === "", "apply succeeded: " + systemLanguagePane.controller.errorCode);
                systemLanguageCheck(i18n.activeLanguage === "ru", "saved language applied globally");
                systemLanguageCheck(systemLanguageFind(win.contentItem, "languageSettings") === systemLanguagePane, "existing settings pane retained");
                systemLanguageCheck(systemLanguageFind(win.contentItem, "languageApply").text === "Применить", "settings translated");
                systemLanguageCheck(systemLanguageFind(calculatorApp.window.contentItem, "calculatorTitle").text === "Калькулятор", "another open app translated");
                systemLanguageCheck(JSON.stringify(calculatorApp.state.history) === systemLanguageCalculator, "Calculator history retained");
                systemLanguageCheck(win.panes.find(pane => pane.id === "general").name === "Основные", "Settings navigation translated");
                systemLanguageCheck(macBar.emojiItems("кот", -1).length > 0, "Russian emoji search");
                macDock.darkMode = true;
            } else if (systemLanguagePhase === 5) {
                systemLanguageCapture("system-language-ru-dark");
            } else if (systemLanguagePhase === 6) {
                macDock.darkMode = false;
            } else if (systemLanguagePhase === 7) {
                systemLanguageCapture("system-language-ru-light");
            } else if (systemLanguagePhase < 8 + win.panes.length) {
                macDock.openPrefs(win.panes[systemLanguagePhase - 8].id);
            } else if (systemLanguagePhase === 8 + win.panes.length) {
                win.hide();
                var futureHour = (new Date().getHours() + 3) % 24;
                clockApp.alarms = [{id: "owned-language-test", h: futureHour, m: 0, label: "Fixture", on: false, days: []}];
                clockApp.open("alarms"); clockApp.testWindow().editing = clockApp.alarms[0]; clockApp.testWindow().sheet = "alarm";
            } else if (systemLanguagePhase === 9 + win.panes.length) {
                var save = systemLanguageFind(clockApp.testWindow().contentItem, "clockAlarmAction_save");
                systemLanguageCheck(save && save.visible, "Russian alarm Save action");
                systemLanguageEvents.mouseClick(save, save.width / 2, save.height / 2, Qt.LeftButton, Qt.NoModifier, 0);
                systemLanguageCheck(clockApp.alarms.length === 1 && clockApp.alarms[0].on, "Save action uses stable ID");
                clockApp.setAlarmOn("owned-language-test", false);
                clockApp.ringing = {kind: "alarm", label: "Fixture", time: "00:00"};
            } else if (systemLanguagePhase === 10 + win.panes.length) {
                var snooze = systemLanguageFind(clockApp.testBanner().contentItem, "clockRingAction_snooze");
                systemLanguageCheck(snooze && snooze.visible, "Russian snooze action");
                systemLanguageEvents.mouseClick(snooze, snooze.width / 2, snooze.height / 2, Qt.LeftButton, Qt.NoModifier, 0);
                systemLanguageCheck(clockApp.snoozes.length === 1 && !clockApp.ringing, "Snooze action uses stable ID");
                clockApp.ringing = {kind: "timer", label: "Fixture", time: "00:00"};
            } else if (systemLanguagePhase === 11 + win.panes.length) {
                var stop = systemLanguageFind(clockApp.testBanner().contentItem, "clockRingAction_stop");
                systemLanguageCheck(stop && stop.visible, "Russian stop action");
                systemLanguageEvents.mouseClick(stop, stop.width / 2, stop.height / 2, Qt.LeftButton, Qt.NoModifier, 0);
                systemLanguageCheck(!clockApp.ringing, "Stop action uses stable ID");
                systemLanguageCheck(clockApp.loaded, "Clock settings loaded");
                clockApp.testAllowRing = true;
                clockApp.nowMs = Date.now();
                clockApp.timer = {state: "running", total: 1000, endAt: clockApp.nowMs - 1, left: 1000, label: ""};
                clockApp.check(); clockApp.testAllowRing = false;
                systemLanguageCheck(clockApp.testRingRecord && clockApp.testRingRecord.defaultLabel && clockApp.testRingRecord.label === "", "default timer label remains canonical");
            } else if (systemLanguagePhase === 12 + win.panes.length) {
                var message = systemLanguageFind(clockApp.testBanner().contentItem, "clockRingMessage");
                systemLanguageCheck(message && message.text === "Готово", "Russian timer completion");
                i18n.language = "en";
            } else if (systemLanguagePhase === 13 + win.panes.length) {
                var messageEn = systemLanguageFind(clockApp.testBanner().contentItem, "clockRingMessage");
                systemLanguageCheck(messageEn && messageEn.text === "Done" && clockApp.ringing.label === "", "completion retranslated without changing state");
                i18n.language = "ru"; clockApp.stopRing();
                clockApp.testWindow().hide();
            } else {
                calculatorApp.window.hide(); win.hide();
                console.log("MACSHELL_SYSTEM_LANGUAGE_NATIVE_PASS: real Settings choice/save, global RU bindings, retained state, all settings panes, emoji search, alarm Save/snooze/stop without audio");
                Qt.quit(); return;
            }
            systemLanguagePhase++;
        } catch (error) { console.error("SYSTEM_LANGUAGE_NATIVE_FAIL", error); Qt.exit(1); }
    }
}

// Injected into the production shell. The internal override is not a public selector.
property int translationPhase: 0
property int translationWaits: 0
property var translationInput: null
property var translationWindow: null
property string translationSnapshot: ""
property string translationOriginalQtLanguage: Qt.uiLanguage
property bool translationSaving: false
function translationFind(item, name) {
    if (!item) return null;
    if (item.objectName === name) return item;
    for (var child of item.children || []) {
        var found = translationFind(child, name);
        if (found) return found;
    }
    return null;
}
function translationCheck(value, reason) { if (!value) throw new Error("TRANSLATION_NATIVE_FAIL: " + reason); }
function translationState() {
    var state = calculatorApp.state;
    return JSON.stringify({expression: state.expression, result: state.result, answer: state.answer, memory: state.memory,
        history: state.history, mode: state.mode, group: state.group, from: state.from, to: state.to});
}
function translationCapture(name) {
    var directory = Quickshell.env("MACSHELL_TRANSLATION_CAPTURE");
    if (!directory) return;
    translationSaving = true;
    calculatorApp.window.contentItem.grabToImage(result => {
        translationCheck(result.saveToFile(directory + "/" + name + ".png"), "save preview");
        translationSaving = false;
    });
}
Timer {
    interval: 400; repeat: true; running: true
    onTriggered: {
        try {
            if (++translationWaits > 55) throw new Error("startup timeout");
            if (!macBar.settingsReady || !macDock.settingsReady || translationSaving) return;
            var i18n = sharedHub.translations, win = calculatorApp.window;
            if (translationPhase === 0) {
                translationCheck(i18n.activeLanguage === "en", "isolated session starts in English");
                i18n.region = "en_US";
                calculatorApp.open("12.5+7.5");
                calculatorApp.state.memoryAction("M+");
            } else if (translationPhase === 1) {
                translationInput = translationFind(win.contentItem, "calculatorExpression");
                translationCheck(translationInput && win.visible, "open production Calculator");
                translationWindow = win;
                translationInput.forceActiveFocus(); translationInput.select(1, 4);
                translationSnapshot = translationState();
                translationCheck(translationFind(win.contentItem, "calculatorTitle").text === "Calculator", "English frame");
                i18n.language = "ru";
            } else if (translationPhase === 2) {
                translationCheck(translationFind(win.contentItem, "calculatorTitle").text === "Калькулятор", "live Russian frame");
                translationCheck(translationFind(win.contentItem, "calculatorWindowControl_0").Accessible.name === "Закрыть калькулятор", "accessibility translated");
                translationCheck(i18n.formatNumber(12.5, 2) === "12.50", "UI language preserves region");
                macDock.darkMode = true;
            } else if (translationPhase === 3) {
                translationCapture("ru-foundation-dark");
            } else if (translationPhase === 4) {
                macDock.darkMode = false;
            } else if (translationPhase === 5) {
                translationCapture("ru-foundation-light");
            } else if (translationPhase === 6) {
                i18n.language = "en"; i18n.region = "ru_RU";
            } else if (translationPhase === 7) {
                translationCheck(translationFind(win.contentItem, "calculatorTitle").text === "Calculator", "live English frame");
                translationCheck(i18n.formatNumber(12.5, 2) === "12,50", "region independent of language");
                translationCheck(win === translationWindow && translationInput === translationFind(win.contentItem, "calculatorExpression"), "existing window and input retained");
                translationCheck(translationInput.selectionStart === 1 && translationInput.selectionEnd === 4, "selection retained");
                translationCheck(translationState() === translationSnapshot, "expression, history and memory retained");
                translationCheck(win.title === "Calculator" && macDock.appOf({appId: "org.quickshell", title: win.title}) === "macshell-calculator", "stable compositor identity");
                translationCheck(Qt.uiLanguage === translationOriginalQtLanguage, "no global Qt language mutation");
                win.hide();
            } else if (translationPhase === 8) {
                translationCheck(!translationFind(win.contentItem, "calculatorExpression"), "hidden pane released");
                console.log("MACSHELL_TRANSLATION_NATIVE_PASS: live RU/EN frame, accessibility, independent formats, retained window/input/state and stable identity");
                Qt.quit(); return;
            }
            translationPhase++;
        } catch (error) { console.error("TRANSLATION_NATIVE_FAIL", error); Qt.exit(1); }
    }
}

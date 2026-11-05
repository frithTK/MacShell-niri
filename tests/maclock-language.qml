property int languageTestStep: 0
property int languageTestWaits: 0
function languageTestFind(item, name) {
    if (!item) return null;
    if (item.objectName === name) return item;
    for (var child of item.children || []) { var found = languageTestFind(child, name); if (found) return found; }
    return null;
}
Timer {
    interval: 200; repeat: true; running: true
    onTriggered: {
        if (!ls.isPrimary || ls.width < 100 || ls.height < 100) return;
        try {
            if (++ls.languageTestWaits > 90) throw new Error("timeout");
            if (Quickshell.env("MACLOCK_PREVIEW") !== "1" || ls.st.pass !== "" || ls.st.busy) throw new Error("preview/auth invariant");
            var hint = ls.languageTestFind(ls, "lockPasswordHint");
            var layout = ls.languageTestFind(ls, "lockKeyboardLayout");
            if (!hint || !layout) return;
            if (ls.languageTestStep === 0 && Language.I18n.activeLanguage === "ru") {
                if (hint.text !== "Введите пароль для разблокировки") throw new Error("Russian hint: " + hint.text);
                if (layout.text !== "Раскладка: Английский (США)" || !layout.visible) throw new Error("Russian layout: " + layout.text);
                ls.st.keyboardLayout = "Russian";
                console.log("MACLOCK_LANGUAGE_RU_READY"); ls.languageTestStep++;
            } else if (ls.languageTestStep === 1 && Language.I18n.activeLanguage === "en") {
                if (hint.text !== "Enter your password to unlock") throw new Error("English hint: " + hint.text);
                if (layout.text !== "Keyboard: Russian") throw new Error("English layout: " + layout.text);
                ls.st.keyboardLayout = "";
                ls.st.message = "Incorrect password";
                console.log("MACLOCK_LANGUAGE_EN_READY"); ls.languageTestStep++;
            } else if (ls.languageTestStep === 2 && Language.I18n.activeLanguage === "ru") {
                if (hint.text !== "Неверный пароль") throw new Error("Russian stored error: " + hint.text);
                if (layout.text !== "Раскладка: Неизвестна") throw new Error("Unknown layout: " + layout.text);
                ls.st.keyboardLayout = "Russian";
                ls.isPrimary = false;
                var secondary = ls.languageTestFind(ls, "lockKeyboardLayoutSecondary");
                if (!secondary || !secondary.visible || secondary.text !== "Раскладка: Русский") throw new Error("Secondary display layout");
                console.log("MACSHELL_MACLOCK_LANGUAGE_PASS: shared preference file, external updates, RU/EN, retained auth state; preview only");
                Qt.quit();
            }
        } catch (error) { console.error("MACLOCK_LANGUAGE_FAIL", error); Qt.exit(1); }
    }
}

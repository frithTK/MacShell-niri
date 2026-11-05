property int keyboardTestPhase: 0
property int keyboardTestWaits: 0
function keyboardTestFind(item, name) {
    if (!item) return null;
    if (item.objectName === name) return item;
    for (var child of item.children || []) { var found = keyboardTestFind(child, name); if (found) return found; }
    return null;
}
Timer {
    interval: 100; repeat: true; running: true
    onTriggered: {
        if (!ls.isPrimary || ls.width < 100 || ls.height < 100) return;
        try {
            if (++ls.keyboardTestWaits > 150) throw new Error("timeout");
            if (Quickshell.env("MACLOCK_PREVIEW") !== "1" || ls.st.pass !== "" || ls.st.busy) throw new Error("preview/auth invariant");
            var badge = ls.keyboardTestFind(ls, "lockKeyboardLayout");
            if (!badge || !ls.shown) return;
            var expected = ["English (US)", "Russian", "English (US)"];
            if (ls.st.keyboardLayout !== expected[ls.keyboardTestPhase]) return;
            var text = Language.I18n.text("lock.keyboard_layout") + ": " + Language.I18n.legacy(expected[ls.keyboardTestPhase]);
            if (!badge.visible || badge.text !== text) throw new Error("badge " + badge.text);
            if (ls.keyboardTestPhase === 1) {
                ls.st.capsLock = true;
                if (ls.st.keyboardLayout !== "Russian" || badge.text !== text) throw new Error("Caps Lock changed layout");
            }
            console.log("MACLOCK_NATIVE_LAYOUT_" + ls.keyboardTestPhase);
            if (++ls.keyboardTestPhase === 3) { console.log("MACLOCK_NATIVE_LAYOUT_PASS"); Qt.quit(); }
        } catch (error) { console.error("MACLOCK_NATIVE_LAYOUT_FAIL", error); Qt.exit(1); }
    }
}

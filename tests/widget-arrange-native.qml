property int arrangePhase: 0
property int arrangeWaits: 0
property string arrangeToken: ""
property bool arrangeSaving: false
function arrangeCheck(value, reason) { if (!value) throw new Error("ARRANGE_FAIL phase " + arrangePhase + ": " + reason); }
function arrangeFind(item, name) {
    if (!item) return null;
    if (item.objectName === name) return item;
    for (var child of item.children || []) { var found = arrangeFind(child, name); if (found) return found; }
    return null;
}
Timer {
    interval: 240; repeat: true; running: true
    onTriggered: {
        if (++arrangeWaits > 160) { console.error("ARRANGE_FAIL timeout phase " + arrangePhase); Qt.exit(1); return; }
        if (!macBar.settingsReady || !macDock.settingsReady || !macWidgets.ready || macWidgets.pending || arrangeSaving) return;
        try {
            var win = macWidgets.desktopWindows[macWidgets.screenName], bar = macWidgets.editControls.contentItem;
            if (arrangePhase === 0) arrangeCheck(macWidgets.addWidget("calendar", "normal", "medium"), "add Calendar");
            else if (arrangePhase === 1) arrangeCheck(macWidgets.addWidget("clock", "dark", "small"), "add Clock");
            else if (arrangePhase === 2) arrangeCheck(macWidgets.addWidget("batteries", "normal", "large"), "add Batteries");
            else if (arrangePhase === 3) {
                macDock.openPrefs("widgets"); calculatorApp.open("24*3");
                arrangeToken = macWidgets.preferences.token;
                macWidgets.editing = true;
            } else if (arrangePhase === 4) {
                arrangeCheck(macWidgets.editControls.active, "Arrange owns keyboard focus");
                arrangeCheck(win.WlrLayershell.layer === WlrLayer.Overlay, "above normal windows");
                arrangeCheck(arrangeFind(win.contentItem, "widgetArrangeBackdrop").visible, "opaque wallpaper covers windows");
                arrangeCheck(bar && bar.height === 40 && bar.y >= 0, "compact controls embedded in desktop");
                arrangeCheck(calculatorApp.window.visible, "application stays open behind Arrange");
                macWidgets.selectWidget(macWidgets.instanceRows[0].id);
                macDock.darkMode = true; macBar.darkMode = true;
            } else if (arrangePhase === 5 || arrangePhase === 10) {
                var directory = Quickshell.env("MACSHELL_ARRANGE_CAPTURE"), theme = arrangePhase === 5 ? "dark" : "light";
                if (directory) {
                    arrangeSaving = true;
                    arrangeFind(win.contentItem, "widgetArrangeScene").grabToImage(result => {
                        if (!result.saveToFile(directory + "/widgets-arrange-" + theme + ".png")) { console.error("ARRANGE_FAIL screenshot"); Qt.exit(1); }
                        arrangeSaving = false;
                    });
                }
            } else if (arrangePhase === 6) {
                macWidgets.setDragging("fixture", true);
            } else if (arrangePhase === 7) {
                arrangeCheck(!arrangeFind(win.contentItem, "widgetArrangeToolbar").visible, "toolbar hides during drag");
                macWidgets.setDragging("fixture", false);
            } else if (arrangePhase === 8) {
                arrangeCheck(arrangeFind(win.contentItem, "widgetArrangeToolbar").visible, "toolbar returns after drag");
                macWidgets.finishEditing(true);
            } else if (arrangePhase === 9) {
                arrangeCheck(win.WlrLayershell.layer === WlrLayer.Bottom && !macWidgets.editControls.visible, "Done returns desktop below windows");
                arrangeCheck(!arrangeFind(win.contentItem, "widgetArrangeBackdrop").visible && !win.editor, "temporary UI unloaded");
                arrangeCheck(macWidgets.preferences.token === arrangeToken, "Arrange and selection do not save positions");
                macDock.darkMode = false; macBar.darkMode = false; macWidgets.editing = true;
            } else if (arrangePhase === 11) {
                macWidgets.finishEditing(true);
            } else if (arrangePhase === 12) {
                arrangeCheck(win.WlrLayershell.keyboardFocus === WlrKeyboardFocus.None && win.WlrLayershell.layer === WlrLayer.Bottom, "keyboard and layer restored");
                arrangeCheck(macWidgets.preferences.token === arrangeToken && calculatorApp.state.result === "72", "settings and application session intact");
                console.log("MACSHELL_WIDGET_ARRANGE_PASS: production overlay, wallpaper, embedded 40px toolbar, drag hiding, two themes, close/reopen, UI release and unchanged saved positions");
                Qt.quit(); return;
            }
            arrangePhase++;
        } catch (error) { console.error(error); Qt.exit(1); }
    }
}

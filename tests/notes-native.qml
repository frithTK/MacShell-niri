property int notesPhase: 0
property int notesWaits: 0
property int notesShots: 0
property bool notesSaving: false
property string notesDeletedId: ""
readonly property bool notesEnglishCapture: Quickshell.env("MACSHELL_README_CAPTURE_EN") === "1"
readonly property string notesSample: notesEnglishCapture ? "Hello 🌍\nMy first note" : "Привет 🌍\nпервая заметка"
Item { parent: notesApp.window.contentItem; TestEvent { id: notesEvents } }
function notesCheck(value, reason) { if (!value) throw new Error("NOTES_FAIL phase " + notesPhase + ": " + reason); }
function notesFind(item, name) {
    if (!item) return null;
    if (item.objectName === name) return item;
    for (var child of item.children || []) { var found = notesFind(child, name); if (found) return found; }
    return null;
}
function notesClick(name) {
    var item = notesFind(notesApp.window.contentItem, name);
    notesCheck(item && item.visible && item.enabled, "interactive " + name);
    notesEvents.mouseClick(item, item.width / 2, item.height / 2, Qt.LeftButton, Qt.NoModifier, 0);
}
Timer {
    interval: 180; repeat: true; running: true
    onTriggered: {
        if (++notesWaits > 180) { console.error("NOTES_FAIL timeout " + notesPhase); Qt.exit(1); return; }
        if (!macBar.settingsReady || !macDock.settingsReady || notesSaving) return;
        var c = notesApp.controller, win = notesApp.window;
        try {
            if (notesPhase === 0) {
                notesCheck(!win.visible && !notesFind(win.contentItem, "notesEditor"), "closed UI unloaded");
                var entry = macBar.searchApps("заметки").find(a => a.id === "macshell-notes");
                notesCheck(entry && macDock.appOf({appId: "org.quickshell", title: "Notes"}) === "macshell-notes", "search and identity");
                macBar.launchApp(entry);
            } else if (notesPhase === 1) {
                if (!c.ready || c.busy) return;
                notesCheck(win.visible && notesFind(win.contentItem, "notesEditor"), "window open");
                notesClick("notesNew");
            } else if (notesPhase === 2) {
                if (!c.selectedId || c.busy) return;
                var editor = notesFind(win.contentItem, "notesEditor");
                editor.forceActiveFocus(); editor.insert(0, notesSample);
                notesCheck(c.dirty, "edit marked dirty");
                editor.cursorPosition = editor.length;
                notesEvents.keyClick(Qt.Key_X, Qt.NoModifier, 0);
                notesCheck(c.body.endsWith("x"), "keyboard edits note");
                notesEvents.keyClick(Qt.Key_Z, Qt.ControlModifier, 0);
                notesCheck(c.body === notesSample, "keyboard undo retains previous text");
                notesApp.requestClose();
            } else if (notesPhase === 3) {
                if (win.visible || c.dirty || c.busy || c.ready) return;
                notesCheck(!notesFind(win.contentItem, "notesEditor"), "closed UI unloaded and service stopped after save");
                notesApp.open();
            } else if (notesPhase === 4) {
                if (!c.ready || c.busy || !c.selectedId) return;
                notesCheck(c.body === notesSample, "persisted text after close and reopen");
                if (sharedHub.translations.activeLanguage !== "ru") { sharedHub.translations.language = "ru"; return; }
                notesCheck(notesFind(win.contentItem, "notesSearch").placeholderText === "Поиск заметок", "live Russian interface");
                notesFind(win.contentItem, "notesEditor").forceActiveFocus();
                notesEvents.keyClick(Qt.Key_F, Qt.ControlModifier, 0);
                notesCheck(notesFind(win.contentItem, "notesSearch").activeFocus, "Ctrl+F focuses search");
                var capture = Quickshell.env("MACSHELL_NOTES_CAPTURE");
                if (capture && notesShots < 2) {
                    if (notesEnglishCapture) sharedHub.translations.language = "en";
                    notesCheck(notesFind(win.contentItem, "notesDelete").Accessible.name === (notesEnglishCapture ? "Delete" : "Удалить"), "delete icon follows interface language");
                    macDock.darkMode = notesShots === 0;
                    var theme = notesShots === 0 ? "dark" : "light";
                    notesSaving = true;
                    Qt.callLater(() => win.contentItem.grabToImage(result => {
                        if (!result.saveToFile(capture + "/notes-" + theme + ".png")) { console.error("NOTES_FAIL screenshot"); Qt.exit(1); }
                        notesShots++; notesSaving = false;
                        if (notesEnglishCapture) sharedHub.translations.language = "ru";
                    }));
                    return;
                }
                var search = notesFind(win.contentItem, "notesSearch"); search.text = notesEnglishCapture ? "first" : "первая";
                notesCheck(notesFind(win.contentItem, "notesList").count === 1, "search finds body");
                search.text = "отсутствует";
                notesCheck(notesFind(win.contentItem, "notesList").count === 0, "search filters");
                search.text = "";
                c.revision = 999;
                c.edit("Несохранённое изменение"); c.flush();
            } else if (notesPhase === 5) {
                if (c.busy || !c.error) return;
                notesCheck(c.dirty && c.body === "Несохранённое изменение", "failed save keeps editor contents");
                notesClick("notesSaveCopy");
            } else if (notesPhase === 6) {
                if (c.busy || c.dirty) return;
                notesCheck(!c.error && c.notes.length === 2 && c.body === "Несохранённое изменение", "copy saved retained text without overwriting original");
                var remove = notesFind(win.contentItem, "notesDelete");
                notesCheck(remove.glyph === "trash" && remove.Accessible.name === "Удалить", "delete icon and accessible name");
                remove.forceActiveFocus(); notesEvents.keyClick(Qt.Key_Space, Qt.NoModifier, 0);
            } else if (notesPhase === 7) {
                if (c.busy || !c.deletedNote) return;
                notesCheck(c.notes.length === 1, "deleted from list"); notesClick("notesUndoDelete");
            } else if (notesPhase === 8) {
                if (c.busy || !c.selectedId) return;
                notesCheck(c.body === "Несохранённое изменение", "undo delete restores text");
                notesDeletedId = c.selectedId; notesClick("notesDelete");
            } else if (notesPhase === 9) {
                if (c.busy || c.deletedNotes.length !== 1) return;
                notesApp.requestClose();
            } else if (notesPhase === 10) {
                if (win.visible || c.ready) return;
                c.deletedNote = null; c.deletedNotes = [];
                notesApp.open();
            } else if (notesPhase === 11) {
                if (!c.ready || c.busy) return;
                notesCheck(c.deletedNotes.length === 1 && c.deletedNotes[0].id === notesDeletedId, "deleted notes loaded from storage after restart");
                notesClick("notesTrash");
            } else if (notesPhase === 12) {
                notesClick("notesRestore_" + notesDeletedId);
            } else if (notesPhase === 13) {
                if (c.busy) return;
                notesCheck(c.body === "Несохранённое изменение" && c.deletedNotes.length === 0, "trash restores note after restart");
                notesClick("notesTrashDone");
                notesPhase++; return;
            } else if (notesPhase === 14) {
                notesClick("notesWindowControl_0");
                notesCheck(!win.visible, "titlebar close uses the normal close path");
                console.log("MACSHELL_NOTES_PASS: catalog, editor, autosave, search, failed save/copy, delete and persistent recovery"); Qt.quit(); return;
            }
            notesPhase++;
        } catch (error) { console.error(error); Qt.exit(1); }
    }
}

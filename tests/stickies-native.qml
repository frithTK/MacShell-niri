property int stickyPhase: 0
property int stickyWait: 0
property string stickyFirstId: ""
property string stickySecondId: ""
property string stickyCopyId: ""
property var stickyFirst: null
property var stickySecond: null
property bool stickySaving: false
property bool stickyCaptured: false
readonly property bool stickyEnglish: Quickshell.env("MACSHELL_STICKIES_LANG") === "en"
readonly property string stickySample: stickyEnglish ? "First sticky note 🌿" : "Первая записка 🌿"
Item { parent: notesApp.window.contentItem; TestEvent { id: stickyEvents } }
function stickyCheck(value, reason) { if (!value) throw new Error("STICKIES_FAIL phase " + stickyPhase + ": " + reason); }
function stickyFind(item, name) {
    if (!item) return null;
    if (item.objectName === name) return item;
    for (var child of item.children || []) { var found = stickyFind(child, name); if (found) return found; }
    return null;
}
function stickyClick(item) { stickyCheck(item && item.visible && item.enabled, "interactive button"); stickyEvents.mouseClick(item, item.width / 2, item.height / 2, Qt.LeftButton, Qt.NoModifier, 0); }
Timer {
    interval: 180; repeat: true; running: true
    onTriggered: {
        if (++stickyWait > 200) { console.error("STICKIES_FAIL timeout " + stickyPhase); Qt.exit(1); return; }
        if (!macBar.settingsReady || !macDock.settingsReady || stickySaving) return;
        try {
            if (stickyPhase === 0) {
                var app = macBar.searchApps("записки").find(item => item.id === "macshell-stickies");
                stickyCheck(app && macDock.appOf({appId: "org.quickshell", title: "Stickies"}) === "macshell-stickies", "catalog and window identity");
                macBar.launchApp(app); stickyPhase++; return;
            }
            if (stickyPhase === 1) {
                if (stickiesApp.windows.length !== 1 || !stickiesApp.windows[0].controller.selectedId) return;
                if (!Niri.connected || !Niri.toplevels.values.some(w => w.title === "Stickies" && w.data.floating)) return;
                stickyFirst = stickiesApp.windows[0]; stickyFirstId = stickyFirst.noteId;
                var editor = stickyFind(stickyFirst.contentItem, "stickyEditor");
                editor.insert(0, stickySample); stickyPhase++; return;
            }
            if (stickyPhase === 2) {
                if (stickyFirst.controller.dirty || stickyFirst.controller.busy) return;
                var capture = Quickshell.env("MACSHELL_STICKIES_CAPTURE");
                if (capture && !stickyCaptured) {
                    sharedHub.translations.language = stickyEnglish ? "en" : "ru";
                    stickySaving = true;
                    Qt.callLater(() => stickyFirst.contentItem.grabToImage(result => {
                        if (!result.saveToFile(capture)) { console.error("STICKIES_FAIL screenshot"); Qt.exit(1); }
                        stickyCaptured = true; stickySaving = false;
                    }));
                    return;
                }
                notesApp.open(); stickyPhase++; return;
            }
            if (stickyPhase === 3) {
                var notes = notesApp.controller;
                if (!notes.ready || notes.busy || !notes.notes.some(n => n.id === stickyFirstId)) return;
                stickyCheck(notes.select(stickyFirstId) && notes.body === stickySample, "sticky text is shared with Notes");
                stickyCheck(notes.service === stickyFirst.controller.service, "Notes and Stickies share one service");
                stickyClick(stickyFind(notesApp.window.contentItem, "notesPin"));
                stickyCheck(stickiesApp.windows.length === 1, "opening same note reuses its window");
                stickyClick(stickyFind(stickyFirst.contentItem, "stickyNew")); stickyPhase++; return;
            }
            if (stickyPhase === 4) {
                if (stickiesApp.windows.length !== 2 || !stickiesApp.windows[1].controller.selectedId) return;
                stickySecond = stickiesApp.windows[1]; stickySecondId = stickySecond.noteId;
                stickyCheck(stickyFirstId !== stickySecondId, "new window has a distinct note");
                stickyCheck(stickySecond.controller.service === stickyFirst.controller.service, "sticky windows share one service");
                stickyFind(stickySecond.contentItem, "stickyEditor").insert(0, "Вторая записка"); stickyPhase = 40; return;
            }
            if (stickyPhase === 40) {
                if (stickySecond.controller.dirty || stickySecond.controller.busy || notesApp.controller.busy) return;
                if (!notesApp.controller.select(stickyFirstId)) { notesApp.controller.reload(); return; }
                notesApp.controller.edit("Из Notes в записку"); notesApp.controller.flush(); stickyPhase = 41; return;
            }
            if (stickyPhase === 41) {
                if (stickyFirst.controller.body !== "Из Notes в записку" || stickyFirst.controller.busy || notesApp.controller.busy) return;
                stickyFirst.controller.edit("Из записки в Notes"); stickyFirst.controller.flush(); stickyPhase = 42; return;
            }
            if (stickyPhase === 42) {
                if (notesApp.controller.body !== "Из записки в Notes" || notesApp.controller.busy || stickyFirst.controller.busy) return;
                stickyPhase = 5; return;
            }
            if (stickyPhase === 5) {
                if (stickySecond.controller.dirty || stickySecond.controller.busy || notesApp.controller.busy) return;
                notesApp.controller.autoRefresh = false; stickyFirst.controller.autoRefresh = false;
                if (!notesApp.controller.select(stickyFirstId)) { notesApp.controller.reload(); return; }
                stickyCheck(notesApp.controller.revision === stickyFirst.controller.revision, "both editors start with the same revision");
                notesApp.controller.edit("Изменено в Notes"); notesApp.controller.flush(); stickyPhase++; return;
            }
            if (stickyPhase === 6) {
                if (notesApp.controller.busy || notesApp.controller.dirty) return;
                stickyFirst.controller.edit("Несохранённый конфликт"); stickyFirst.controller.flush(); stickyPhase++; return;
            }
            if (stickyPhase === 7) {
                if (stickyFirst.controller.busy || !stickyFirst.controller.error) return;
                stickyCheck(stickyFirst.controller.dirty && stickyFirst.controller.body === "Несохранённый конфликт", "conflicting text is retained");
                stickyClick(stickyFind(stickyFirst.contentItem, "stickySaveCopy")); stickyPhase++; return;
            }
            if (stickyPhase === 8) {
                if (stickyFirst.controller.busy || stickyFirst.controller.dirty || stickyFirst.noteId === stickyFirstId) return;
                stickyCheck(stickyFirst.controller.body === "Несохранённый конфликт", "conflict saved as a separate note");
                stickyCopyId = stickyFirst.noteId;
                stickyFirst.controller.edit("Сохранено при закрытии");
                stickyClick(stickyFind(stickyFirst.contentItem, "stickyWindowControl_0")); stickyPhase++; return;
            }
            if (stickyPhase === 9) {
                if (stickiesApp.windows.length !== 1) return;
                stickyCheck(stickiesApp.windows[0] === stickySecond, "closing one window retains the other");
                stickySecond.requestClose(); stickyPhase++; return;
            }
            if (stickyPhase === 10) {
                if (stickiesApp.windows.length !== 0) return;
                if (!notesApp.controller.reload()) return;
                stickyPhase++; return;
            }
            if (stickyPhase === 11) {
                if (notesApp.controller.busy) return;
                var all = notesApp.controller.notes;
                stickyCheck(all.some(n => n.id === stickyFirstId && n.body === "Изменено в Notes"), "original note preserved");
                stickyCheck(all.some(n => n.id === stickyCopyId && n.body === "Сохранено при закрытии"), "close waits for copy to save");
                stickyCheck(all.some(n => n.id === stickySecondId && n.body === "Вторая записка"), "second note preserved");
                notesApp.requestClose();
                stickyPhase++; return;
            }
            if (stickyPhase === 12) {
                if (notesApp.window.visible || notesApp.controller.busy || sharedHub.notesService.enabled) return;
                stickyCheck(!sharedHub.notesService.ready, "shared service stops when all editors close");
                console.log("MACSHELL_STICKIES_PASS: shared storage, multiple windows, conflicts, copy and close"); Qt.quit(); return;
            }
        } catch (error) { console.error(error); Qt.exit(1); }
    }
}

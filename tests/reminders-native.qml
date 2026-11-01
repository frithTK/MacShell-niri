property int remindersPhase: 0
property int remindersWaits: 0
property string remindersTaskId: ""
property string remindersListId: ""
property int remindersSettle: 0
property int remindersShots: 0
property bool remindersSaving: false
property bool remindersEditShot: false
property bool remindersFailureSent: false
property bool remindersFailureChecked: false
property int remindersUnknownStage: 0
Item { parent: remindersApp.window.contentItem; TestEvent { id: remindersEvents } }
Process {
    id: remindersInjectUncertain
    command: ["python3", "-c", "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute(\"UPDATE tasks SET alert_state='uncertain',alert_error='delivery_unknown' WHERE id=?\",(sys.argv[2],)); c.commit(); c.close()", Quickshell.env("MACSHELL_REMINDERS_DATA_HOME") + "/macshell/reminders/tasks.sqlite3", remindersTaskId]
}
function remindersCheck(value, reason) { if (!value) throw new Error("REMINDERS_FAIL phase " + remindersPhase + ": " + reason); }
function remindersFind(item, name) {
    if (!item) return null;
    if (item.objectName === name) return item;
    for (var child of item.children || []) { var found = remindersFind(child, name); if (found) return found; }
    return null;
}
function remindersClick(name) {
    var item = remindersFind(remindersApp.window.contentItem, name);
    remindersCheck(item && item.visible && item.enabled, "interactive " + name);
    remindersEvents.mouseClick(item, item.width / 2, item.height / 2, Qt.LeftButton, Qt.NoModifier, 0);
}
Timer {
    interval: 180; repeat: true; running: true
    onTriggered: {
        if (++remindersWaits > 180) { console.error("REMINDERS_FAIL timeout " + remindersPhase); Qt.exit(1); return; }
        if (!macBar.settingsReady || !macDock.settingsReady || remindersSaving) return;
        var c = remindersApp.controller, win = remindersApp.window;
        try {
            if (remindersPhase === 0) {
                if (sharedHub.translations.activeLanguage !== "ru") { sharedHub.translations.language = "ru"; return; }
                var entry = macBar.searchApps("напоминания").find(a => a.id === "macshell-reminders");
                remindersCheck(entry && entry.name === "Напоминания", "Russian catalog search");
                remindersCheck(macDock.appOf({appId: "org.quickshell", title: "Reminders"}) === "macshell-reminders", "window identity");
                macBar.launchApp(entry);
            } else if (remindersPhase === 1) {
                if (!c.ready || c.busy || !c.lists.length) return;
                remindersFind(win.contentItem, "remindersNewList").text = "Покупки";
                remindersClick("remindersAddList");
            } else if (remindersPhase === 2) {
                if (c.busy || c.selectedList === "inbox") return;
                remindersCheck(c.lists.some(l => l.name === "Покупки"), "created list");
                remindersCheck(remindersFind(win.contentItem, "remindersNewList").text === "", "saved list draft clears");
                var createdList = c.selectedList, inboxItem = remindersFind(win.contentItem, "remindersList_inbox");
                remindersListId = createdList;
                remindersCheck(inboxItem, "default list control"); inboxItem.forceActiveFocus();
                remindersEvents.keyClick(Qt.Key_Space, Qt.NoModifier, 0);
                remindersCheck(c.selectedList === "inbox", "keyboard selects list");
                var customItem = remindersFind(win.contentItem, "remindersList_" + createdList);
                remindersCheck(customItem, "custom list control"); customItem.forceActiveFocus();
                remindersEvents.keyClick(Qt.Key_Return, Qt.NoModifier, 0);
                remindersCheck(c.selectedList === createdList, "keyboard restores list");
                remindersFind(win.contentItem, "remindersNewTask").text = "Купить чай 🌿";
                remindersClick("remindersAddTask");
            } else if (remindersPhase === 3) {
                if (c.busy || c.tasks.length !== 1) return;
                remindersCheck(remindersFind(win.contentItem, "remindersNewTask").text === "", "saved task draft clears");
                remindersTaskId = c.tasks[0].id;
                remindersClick("remindersToggle_" + remindersTaskId);
            } else if (remindersPhase === 4) {
                if (c.busy || !c.tasks[0].done) return;
                remindersClick("remindersEdit_" + remindersTaskId);
            } else if (remindersPhase === 5) {
                var edit = remindersFind(win.contentItem, "remindersEditInput");
                if (!edit || !edit.visible) return;
                var due = remindersFind(win.contentItem, "remindersDueInput");
                edit.text = "Купить зелёный чай 🌿"; due.text = "2030-02-30 14:30";
                remindersCheck(!remindersFind(win.contentItem, "remindersEditSave").enabled, "invalid date is blocked");
                var repeat = remindersFind(win.contentItem, "remindersRepeat");
                remindersCheck(repeat && repeat.visible && repeat.model.length === 4, "repeat control available");
                repeat.currentIndex = 0; repeat.forceActiveFocus();
                remindersEvents.keyClick(Qt.Key_End, Qt.NoModifier, 0);
                remindersCheck(repeat.rule === "monthly", "repeat can be selected with keyboard");
                due.text = "";
                sharedHub.translations.language = "en";
                remindersCheck(repeat.rule === "monthly", "repeat selection survives language change");
                sharedHub.translations.language = "ru";
                remindersCheck(!remindersFind(win.contentItem, "remindersEditSave").enabled, "repeat requires a due time");
                due.text = "2030-01-02 14:30";
                var editCapture = Quickshell.env("MACSHELL_REMINDERS_CAPTURE");
                if (editCapture && !remindersEditShot) {
                    remindersSaving = true;
                    win.contentItem.grabToImage(result => {
                        if (!result.saveToFile(editCapture + "/reminders-edit.png")) { console.error("REMINDERS_FAIL screenshot"); Qt.exit(1); }
                        remindersEditShot = true; remindersSaving = false;
                    });
                    return;
                }
                remindersClick("remindersEditSave");
            } else if (remindersPhase === 6) {
                if (c.busy || c.tasks[0].title !== "Купить зелёный чай 🌿") return;
                remindersCheck(c.tasks[0].due_at === new Date(2030, 0, 2, 14, 30).getTime(), "local due time stored");
                remindersCheck(c.tasks[0].repeat_rule === "monthly", "repeat rule stored");
                remindersClick("remindersDelete_" + remindersTaskId);
            } else if (remindersPhase === 7) {
                if (c.busy || !c.lastDeleted) return;
                remindersCheck(c.tasks.length === 0, "deleted task hidden"); remindersClick("remindersUndoDelete");
            } else if (remindersPhase === 8) {
                if (c.busy || c.tasks.length !== 1) return;
                remindersCheck(c.tasks[0].id === remindersTaskId && c.tasks[0].done, "undo retains identity and state");
                if (++remindersSettle < 3) return;
                remindersClick("remindersRenameList");
            } else if (remindersPhase === 9) {
                var listEdit = remindersFind(win.contentItem, "remindersListEditInput");
                if (!listEdit || !listEdit.visible) return;
                listEdit.text = "Покупки домой"; remindersClick("remindersListEditSave");
            } else if (remindersPhase === 10) {
                if (c.busy || !c.lists.some(l => l.name === "Покупки домой")) return;
                remindersClick("remindersDeleteList");
            } else if (remindersPhase === 11) {
                var confirm = remindersFind(win.contentItem, "remindersConfirmListDelete");
                if (!confirm || !confirm.visible) return;
                remindersClick("remindersConfirmListDelete");
            } else if (remindersPhase === 12) {
                if (c.busy || !c.lastDeletedList) return;
                remindersCheck(c.selectedList === "inbox" && c.tasks.length === 0, "list and its tasks hidden");
                remindersApp.requestClose();
            } else if (remindersPhase === 13) {
                if (win.visible || c.busy) return;
                if (remindersApp.backgroundEnabled) { remindersCheck(c.ready, "scheduler survives window close"); remindersApp.backgroundEnabled = false; return; }
                if (c.ready) return;
                c.lastDeletedList = null; c.lastDeleted = null; remindersApp.backgroundEnabled = true; remindersApp.open();
            } else if (remindersPhase === 14) {
                if (!c.ready || c.busy || !c.deletedLists.length) return;
                remindersClick("remindersTrash");
            } else if (remindersPhase === 15) {
                var restoreList = remindersFind(win.contentItem, "remindersRestore_" + remindersListId);
                if (!restoreList || !restoreList.visible) return;
                remindersClick("remindersRestore_" + remindersListId);
            } else if (remindersPhase === 16) {
                if (c.busy || c.selectedList === "inbox" || c.tasks.length !== 1) return;
                remindersCheck(c.tasks[0].id === remindersTaskId, "list restore retains task");
                remindersClick("remindersTrashClose");
            } else if (remindersPhase === 17) {
                if (c.busy) return;
                remindersClick("remindersDelete_" + remindersTaskId);
            } else if (remindersPhase === 18) {
                if (c.busy || !c.deletedTasks.length) return;
                remindersApp.requestClose();
            } else if (remindersPhase === 19) {
                if (win.visible || c.busy) return;
                if (remindersApp.backgroundEnabled) { remindersApp.backgroundEnabled = false; return; }
                if (c.ready) return;
                c.lastDeleted = null; remindersApp.backgroundEnabled = true; remindersApp.open();
            } else if (remindersPhase === 20) {
                if (!c.ready || c.busy || !c.deletedTasks.length) return;
                remindersClick("remindersTrash");
            } else if (remindersPhase === 21) {
                var restoreTask = remindersFind(win.contentItem, "remindersRestore_" + remindersTaskId);
                if (!restoreTask || !restoreTask.visible) return;
                remindersClick("remindersRestore_" + remindersTaskId);
            } else if (remindersPhase === 22) {
                if (c.busy || c.tasks.length !== 1) return;
                remindersCheck(c.tasks[0].id === remindersTaskId, "trash restores deleted task");
                remindersClick("remindersTrashClose");
            } else if (remindersPhase === 23) {
                var capture = Quickshell.env("MACSHELL_REMINDERS_CAPTURE");
                if (capture && remindersShots < 2) {
                    macDock.darkMode = remindersShots === 0;
                    var theme = remindersShots === 0 ? "dark" : "light";
                    remindersSaving = true;
                    Qt.callLater(() => win.contentItem.grabToImage(result => {
                        if (!result.saveToFile(capture + "/reminders-" + theme + ".png")) { console.error("REMINDERS_FAIL screenshot"); Qt.exit(1); }
                        remindersShots++; remindersSaving = false;
                    }));
                    return;
                }
                remindersApp.requestClose();
            } else if (remindersPhase === 24) {
                if (win.visible || c.busy) return;
                remindersCheck(!remindersFind(win.contentItem, "remindersNewTask"), "closed UI unloaded"); remindersApp.open();
            } else if (remindersPhase === 25) {
                if (!c.ready || c.busy || c.tasks.length !== 1) return;
                remindersCheck(c.tasks[0].title === "Купить зелёный чай 🌿" && c.tasks[0].done, "reopened task");
                if (remindersUnknownStage === 0) { remindersInjectUncertain.running = true; remindersUnknownStage = 1; return; }
                if (remindersUnknownStage === 1) {
                    if (remindersInjectUncertain.running || c.tasks[0].alert_state !== "uncertain") return;
                    remindersClick("remindersResolve_" + remindersTaskId); remindersUnknownStage = 2; return;
                }
                if (remindersUnknownStage === 2) {
                    var handled = remindersFind(win.contentItem, "remindersMarkHandled");
                    if (!handled || !handled.visible) return;
                    remindersClick("remindersMarkHandled"); remindersUnknownStage = 3; return;
                }
                if (remindersUnknownStage === 3) {
                    if (c.tasks[0].alert_state !== "delivered") return;
                    remindersUnknownStage = 4;
                }
                if (!remindersFailureSent) {
                    remindersFind(win.contentItem, "remindersNewTask").text = "x".repeat(501);
                    remindersClick("remindersAddTask"); remindersFailureSent = true; return;
                }
                if (!remindersFailureChecked) {
                    if (!c.error) return;
                    var draft = remindersFind(win.contentItem, "remindersNewTask");
                    remindersCheck(draft.text.length === 501 && c.tasks.length === 1, "failed save retains input");
                    draft.clear(); c.load(); remindersFailureChecked = true; return;
                }
                if (c.error) return;
                var search = remindersFind(win.contentItem, "remindersSearch"); search.text = "зелёный";
                remindersCheck(remindersFind(win.contentItem, "remindersTasks").count === 1, "search finds task");
                search.text = "нет такого";
                remindersCheck(remindersFind(win.contentItem, "remindersTasks").count === 0, "search filters task");
                remindersApp.requestClose();
            } else if (remindersPhase === 26) {
                if (win.visible) return;
                remindersApp.open();
            } else if (remindersPhase === 27) {
                if (!c.ready || c.busy || c.tasks.length !== 1) return;
                remindersCheck(c.tasks[0].repeat_rule === "monthly" && c.tasks[0].done, "repeat persists on reopen");
                remindersClick("remindersToggle_" + remindersTaskId);
            } else if (remindersPhase === 28) {
                if (c.busy || c.tasks[0].done) return;
                remindersClick("remindersToggle_" + remindersTaskId);
            } else if (remindersPhase === 29) {
                if (c.busy || c.tasks[0].due_at === new Date(2030, 0, 2, 14, 30).getTime()) return;
                remindersCheck(c.tasks.length === 1 && !c.tasks[0].done && c.tasks[0].due_at === new Date(2030, 1, 2, 14, 30).getTime(), "completion schedules the next occurrence");
                console.log("MACSHELL_REMINDERS_PASS: lists, tasks, completion, repeats, edit, undo, restart and search"); Qt.quit(); return;
            }
            remindersPhase++;
        } catch (error) { console.error(error); Qt.exit(1); }
    }
}

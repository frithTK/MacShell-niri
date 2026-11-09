property int calendarPhase: 0
property int calendarWaits: 0
property string calendarId: ""
property int calendarShots: 0
property bool calendarSaving: false
property int calendarEditShots: 0
Item { parent: calendarApp.window.contentItem; TestEvent { id: calendarInput } }
function calendarCheck(value, reason) { if (!value) throw new Error("CALENDAR_FAIL phase " + calendarPhase + ": " + reason); }
function calendarFind(item, name) {
    if (!item) return null;
    if (item.objectName === name) return item;
    for (var child of item.children || []) { var found = calendarFind(child, name); if (found) return found; }
    return null;
}
function calendarClick(name) {
    var item = calendarFind(calendarApp.window.contentItem, name);
    calendarCheck(item && item.visible && item.enabled, "interactive " + name);
    calendarInput.mouseClick(item, item.width / 2, item.height / 2, Qt.LeftButton, Qt.NoModifier, 0);
}
Timer {
    interval: 180; repeat: true; running: true
    onTriggered: {
        if (++calendarWaits > 200) { console.error("CALENDAR_FAIL timeout " + calendarPhase); Qt.exit(1); return; }
        if (!macBar.settingsReady || !macDock.settingsReady || calendarSaving) return;
        var c = calendarApp.controller, win = calendarApp.window;
        try {
            if (calendarPhase === 0) {
                if (sharedHub.translations.activeLanguage !== "ru") { sharedHub.translations.language = "ru"; return; }
                var entry = macBar.searchApps("календарь").find(a => a.id === "macshell-calendar");
                calendarCheck(entry && entry.name === "Календарь", "catalog search");
                calendarCheck(macDock.appOf({appId: "org.quickshell", title: "Calendar"}) === "macshell-calendar", "window identity");
                calendarApp.selectDay(new Date(2030, 0, 2)); macBar.launchApp(entry);
            } else if (calendarPhase === 1) {
                if (!c.ready || c.busy) return;
                calendarClick("calendarAdd");
            } else if (calendarPhase === 2) {
                var title = calendarFind(win.contentItem, "calendarEventTitle");
                if (!title || !title.visible) return;
                title.text = "Тестовое событие";
                calendarFind(win.contentItem, "calendarAllDay").checked = true;
                var date = calendarFind(win.contentItem, "calendarEventDate");
                date.text = "2030-02-30"; calendarCheck(!calendarFind(win.contentItem, "calendarSave").enabled, "invalid date rejected");
                date.text = "2030-01-02";
                var capture = Quickshell.env("MACSHELL_CALENDAR_CAPTURE");
                if (capture && calendarEditShots < 2) {
                    macDock.darkMode = calendarEditShots === 0;
                    var editTheme = calendarEditShots === 0 ? "dark" : "light";
                    calendarSaving = true;
                    Qt.callLater(() => win.contentItem.grabToImage(result => {
                        if (!result.saveToFile(capture + "/calendar-edit-" + editTheme + ".png")) { console.error("CALENDAR_FAIL screenshot"); Qt.exit(1); }
                        calendarEditShots++; calendarSaving = false;
                    }));
                    return;
                }
                calendarClick("calendarSave");
            } else if (calendarPhase === 3) {
                if (c.busy || c.events.length !== 1) return;
                calendarCheck(c.events[0].all_day && c.events[0].day === "2030-01-02", "all-day event persisted");
                calendarId = c.events[0].id;
                calendarClick("calendarEdit_" + calendarId);
            } else if (calendarPhase === 4) {
                var title = calendarFind(win.contentItem, "calendarEventTitle");
                if (!title || !title.visible) return;
                title.text = Quickshell.env("MACSHELL_CALENDAR_CAPTURE_LANGUAGE") === "en" ? "Evening meeting" : "Вечерняя встреча"; calendarFind(win.contentItem, "calendarAllDay").checked = false;
                var start = calendarFind(win.contentItem, "calendarEventStart"), end = calendarFind(win.contentItem, "calendarEventEnd");
                start.text = "2030-01-02 23:00"; end.text = "2030-01-02 22:00";
                calendarCheck(!calendarFind(win.contentItem, "calendarSave").enabled, "end before start rejected");
                end.text = "2030-01-03 01:00"; calendarClick("calendarSave");
            } else if (calendarPhase === 5) {
                if (c.busy || c.events.length !== 1 || c.events[0].all_day) return;
                calendarCheck(c.events[0].start_ms === new Date(2030, 0, 2, 23).getTime(), "timed instant persisted");
                var midnight = {all_day: 0, start_ms: new Date(2030, 0, 2, 23).getTime(), end_ms: new Date(2030, 0, 3, 0).getTime()};
                calendarCheck(calendarApp.onDay(midnight, new Date(2030, 0, 2)) && !calendarApp.onDay(midnight, new Date(2030, 0, 3)), "midnight end is exclusive");
                calendarApp.selectDay(new Date(2030, 0, 3));
                if (calendarApp.dayEvents.length !== 1) return;
                calendarClick("calendarDelete_" + calendarId);
            } else if (calendarPhase === 6) {
                if (c.busy || c.events.length || c.deleted.length !== 1) return;
                calendarApp.requestClose();
            } else if (calendarPhase === 7) {
                if (win.visible || c.ready) return;
                calendarApp.open();
            } else if (calendarPhase === 8) {
                if (!c.ready || c.busy || c.deleted.length !== 1) return;
                calendarClick("calendarTrash");
            } else if (calendarPhase === 9) {
                var restore = calendarFind(win.contentItem, "calendarRestore_" + calendarId);
                if (!restore || !restore.visible) return;
                calendarClick("calendarRestore_" + calendarId);
            } else if (calendarPhase === 10) {
                if (c.busy || c.events.length !== 1) return;
                calendarCheck(c.events[0].id === calendarId, "restored identity");
                calendarClick("calendarTrashClose");
            } else if (calendarPhase === 11) {
                var capture = Quickshell.env("MACSHELL_CALENDAR_CAPTURE");
                if (capture && calendarShots < 2) {
                    var captureLanguage = Quickshell.env("MACSHELL_CALENDAR_CAPTURE_LANGUAGE") === "en" ? "en" : "ru";
                    if (sharedHub.translations.activeLanguage !== captureLanguage) { sharedHub.translations.language = captureLanguage; return; }
                    sharedHub.translations.region = captureLanguage === "en" ? "en_US" : "ru_RU";
                    macDock.darkMode = calendarShots === 0;
                    var theme = calendarShots === 0 ? "dark" : "light";
                    calendarSaving = true;
                    Qt.callLater(() => win.contentItem.grabToImage(result => {
                        if (!result.saveToFile(capture + "/calendar-" + theme + ".png")) { console.error("CALENDAR_FAIL screenshot"); Qt.exit(1); }
                        calendarShots++; calendarSaving = false;
                    }));
                    return;
                }
                sharedHub.translations.language = "en";
                calendarCheck(calendarApp.tr("title") === "Calendar", "live English localization");
                calendarApp.requestClose();
            } else if (calendarPhase === 12) {
                if (win.visible || c.ready) return;
                calendarCheck(!calendarFind(win.contentItem, "calendarEvents"), "closed UI unloaded");
                calendarApp.open();
            } else if (calendarPhase === 13) {
                if (!c.ready || c.busy || c.events.length !== 1) return;
                calendarCheck(c.events[0].title === (Quickshell.env("MACSHELL_CALENDAR_CAPTURE_LANGUAGE") === "en" ? "Evening meeting" : "Вечерняя встреча"), "event survives restart");
                console.log("MACSHELL_CALENDAR_PASS: catalog, dates, create, edit, restore, restart and localization"); Qt.quit(); return;
            }
            calendarPhase++;
        } catch (error) { console.error(error); Qt.exit(1); }
    }
}

property int sessionPhase: 0
property int sessionWait: 0
property int sessionSettle: 0
readonly property string sessionStage: Quickshell.env("MACSHELL_STICKIES_STAGE")
function sessionCheck(value, reason) { if (!value) throw new Error("STICKIES_SESSION_FAIL " + sessionStage + ": " + reason); }
function sessionWindow(body) { return stickiesApp.windows.find(w => w.controller.body === body); }
Timer {
    interval: 180; repeat: true; running: true
    onTriggered: {
        if (++sessionWait > 200) { console.error("STICKIES_SESSION_FAIL timeout " + sessionStage + " phase " + sessionPhase); Qt.exit(1); return; }
        if (!Niri.connected || !macBar.settingsReady || !macDock.settingsReady || stickiesApp.restorePending) return;
        try {
            if (sessionStage === "create") {
                if (sessionPhase === 0) { stickiesApp.open(); stickiesApp.open(); sessionPhase++; return; }
                if (sessionPhase === 1) {
                    if (stickiesApp.windows.length !== 2 || stickiesApp.windows.some(w => !w.noteId || !w.niriId || w.geometryDelay.running || w.controller.busy)) return;
                    stickiesApp.windows[0].controller.edit("Session first"); stickiesApp.windows[1].controller.edit("Session second");
                    var first = stickiesApp.windows[0].niriId, second = stickiesApp.windows[1].niriId;
                    Niri.request([
                        {Action: {SetWindowWidth: {id: first, change: {SetFixed: 410}}}},
                        {Action: {SetWindowHeight: {id: first, change: {SetFixed: 320}}}},
                        {Action: {MoveFloatingWindow: {id: first, x: {SetFixed: 80}, y: {SetFixed: 100}}}},
                        {Action: {SetWindowWidth: {id: second, change: {SetFixed: 370}}}},
                        {Action: {SetWindowHeight: {id: second, change: {SetFixed: 270}}}},
                        {Action: {MoveFloatingWindow: {id: second, x: {SetFixed: 500}, y: {SetFixed: 250}}}}
                    ]);
                    sessionPhase++; return;
                }
                if (sessionPhase === 2) {
                    if (stickiesApp.windows.some(w => w.controller.busy || w.controller.dirty) || stickiesApp.sessionDirty || stickiesApp.sessionRequest) return;
                    var a = sessionWindow("Session first"), b = sessionWindow("Session second");
                    if (!a || !b || a.savedGeometry.width !== 410 || b.savedGeometry.width !== 370) return;
                    if (++sessionSettle < 5) return;
                    sessionCheck(a.savedGeometry.x === 80 && a.savedGeometry.y === 100, "first position saved: " + JSON.stringify(a.savedGeometry));
                    sessionCheck(b.savedGeometry.x === 500 && b.savedGeometry.y === 250, "second position saved: " + JSON.stringify(b.savedGeometry));
                    console.log("STICKIES_SESSION_PASS create"); Qt.quit(); return;
                }
            } else if (sessionStage === "restore") {
                if (sessionPhase === 1) {
                    if (stickiesApp.windows.length !== 1 || stickiesApp.sessionDirty || stickiesApp.sessionRequest) return;
                    console.log("STICKIES_SESSION_PASS restore"); Qt.quit(); return;
                }
                if (stickiesApp.windows.length !== 2 || stickiesApp.windows.some(w => !w.niriId || w.geometryDelay.running || w.controller.busy || !w.controller.ready)) return;
                var firstRestored = sessionWindow("Session first"), secondRestored = sessionWindow("Session second");
                if (!firstRestored || !secondRestored) return;
                var firstData = Niri.windowMap[String(firstRestored.niriId)].data, secondData = Niri.windowMap[String(secondRestored.niriId)].data;
                sessionCheck(firstData.size[0] === 410 && firstData.size[1] === 320 && firstData.at[0] === 80 && firstData.at[1] === 100, "first restored: " + JSON.stringify(firstData));
                sessionCheck(secondData.size[0] === 370 && secondData.size[1] === 270 && secondData.at[0] === 500 && secondData.at[1] === 250, "second restored: " + JSON.stringify(secondData));
                secondRestored.requestClose(); sessionPhase++; return;
            } else if (sessionStage === "closed") {
                if (sessionPhase === 0) {
                    if (stickiesApp.windows.length !== 1 || !stickiesApp.windows[0].controller.ready || stickiesApp.windows[0].controller.busy) return;
                    sessionCheck(stickiesApp.windows[0].controller.body === "Session first", "closed window remains closed");
                    stickiesApp.windows[0].requestClose(); sessionPhase++; return;
                }
                if (stickiesApp.windows.length || stickiesApp.sessionDirty || stickiesApp.sessionRequest || sharedHub.notesService.enabled) return;
                console.log("STICKIES_SESSION_PASS closed"); Qt.quit(); return;
            } else if (sessionStage === "empty") {
                sessionCheck(stickiesApp.windows.length === 0, "last closed window stays closed");
                console.log("STICKIES_SESSION_PASS empty"); Qt.quit(); return;
            }
        } catch (error) { console.error(error); Qt.exit(1); }
    }
}

property int bridgePhase: 0
property int bridgeWaits: 0
property double bridgeFirstId: 0
property double bridgeSecondId: 0
property var bridgeOriginalWindow: null
property bool bridgeSawDisconnect: false
property string bridgeOldSession: ""
Window { id: bridgeFirst; title: "Synthetic Bridge First"; width: 440; height: 280; visible: true }
Window { id: bridgeSecond; title: "Synthetic Bridge Second"; width: 440; height: 280; visible: true }
Timer { id: bridgeMeasureHold; interval: 16000; onTriggered: { console.log("MACSHELL_NIRI_BRIDGE_NATIVE_PASS: isolated shell measurement"); Qt.quit(); } }
function bridgeCheck(value, reason) { if (!value) throw new Error("NIRI_BRIDGE_FAIL phase " + bridgePhase + ": " + reason); }
Timer {
    interval: 150; repeat: true; running: true
    onTriggered: {
        if (++bridgeWaits > 180) { console.error("NIRI_BRIDGE_FAIL timeout " + bridgePhase); Qt.exit(1); return; }
        try {
            if (bridgePhase === 0) {
                if (!Niri.connected || !Niri.monitorData.length || !Niri.workspaces.values.length) return;
                var first = Niri.clients.find(w => w.title === "Synthetic Bridge First");
                var second = Niri.clients.find(w => w.title === "Synthetic Bridge Second");
                if (!first || !second) return;
                bridgeFirstId = first.id; bridgeSecondId = second.id;
                bridgeOriginalWindow = Niri.windowMap[String(first.id)];
                bridgeCheck(!!bridgeOriginalWindow && first.workspace_id !== undefined, "window and workspace state");
                bridgeCheck(Niri.workspaces.values.some(w => w.toplevels.values.indexOf(bridgeOriginalWindow) >= 0), "window belongs to a workspace");
                var appKey = macDock.keyOf(macDock.appOf(bridgeOriginalWindow));
                bridgeCheck(macDock.windowsFor(appKey).indexOf(bridgeOriginalWindow) >= 0, "Dock sees the window");
                bridgeCheck(macBar.swBuild().some(app => app.win && (app.win.id === first.id || app.win.id === second.id)), "switcher sees a synthetic window");
                bridgeOldSession = Niri.bridgeSession;
                bridgeFirst.title = "Synthetic Bridge Renamed";
            } else if (bridgePhase === 1) {
                var item = Niri.windowMap[String(bridgeFirstId)];
                if (!item || item.title !== "Synthetic Bridge Renamed") return;
                bridgeCheck(item === bridgeOriginalWindow, "window object retained on title update");
                Niri.request({Action: {FocusWindow: {id: bridgeFirstId}}});
            } else if (bridgePhase === 2) {
                if (!Niri.activeToplevel || Niri.activeToplevel.id !== bridgeFirstId) return;
                bridgeSecond.close();
            } else if (bridgePhase === 3) {
                if (Niri.windowMap[String(bridgeSecondId)]) return;
                bridgeCheck(Niri.windowMap[String(bridgeFirstId)] === bridgeOriginalWindow, "remaining window survives close");
                if (Quickshell.env("MACSHELL_TEST_BRIDGE_CRASH") === "1") {
                    console.log("MACSHELL_NIRI_BRIDGE_REQUEST_CRASH"); bridgePhase++; return;
                }
                if (Quickshell.env("MACSHELL_TEST_BRIDGE_MEASURE") === "1") {
                    console.log("MACSHELL_NIRI_BRIDGE_MEASURE_READY"); bridgeMeasureHold.start(); bridgePhase = 5; return;
                }
                console.log("MACSHELL_NIRI_BRIDGE_NATIVE_PASS: state, title, focus command and window close");
                Qt.quit(); return;
            } else if (bridgePhase === 4) {
                if (!Niri.connected) { bridgeSawDisconnect = true; return; }
                if (!bridgeSawDisconnect || !Niri.windowMap[String(bridgeFirstId)]) return;
                bridgeCheck(Niri.windowMap[String(bridgeFirstId)].title === "Synthetic Bridge Renamed", "state restored after crash");
                if (bridgeOldSession) {
                    bridgeCheck(!!Niri.bridgeSession && Niri.bridgeSession !== bridgeOldSession, "new bridge session after crash");
                    var staleTitles = {}; staleTitles[String(bridgeFirstId)] = "Stale synthetic title";
                    Niri.accept({connected: true, bridgeSession: bridgeOldSession, titles: staleTitles});
                    bridgeCheck(Niri.windowMap[String(bridgeFirstId)].title === "Synthetic Bridge Renamed", "stale title rejected");
                    Niri.accept({connected: true, bridgeSession: bridgeOldSession,
                                 state: {monitors: [], windows: [], workspaces: [], keyboard: {names: [], current_idx: 0}, overview: false}});
                    bridgeCheck(!!Niri.windowMap[String(bridgeFirstId)] && Niri.connected, "stale full state rejected");
                }
                console.log("MACSHELL_NIRI_BRIDGE_NATIVE_PASS: state restored after bridge crash");
                Qt.quit(); return;
            }
            bridgePhase++;
        } catch (error) { console.error(error); Qt.exit(1); }
    }
}

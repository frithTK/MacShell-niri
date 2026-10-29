// Inserted in the real shell, with isolated settings and disconnected devices.
property int activityPhase: 0
property int activityWaits: 0
property string activityOutput: ""
property int activityPid: 0
property string activityCopy: ""
property double activityHeldTime: 0
TestEvent { id: activityEvents }
function activityCheck(value, reason) { if (!value) throw new Error("ACTIVITY_WIDGET_FAIL phase " + activityPhase + ": " + reason); }
function activityFind(item, name) {
    if (!item) return null;
    if (item.objectName === name) return item;
    for (var child of item.children || []) { var result = activityFind(child, name); if (result) return result; }
    return null;
}
function activityVisual() {
    var window = macWidgets.desktopWindows[activityOutput];
    return window ? activityFind(window.contentItem, "widgetVisual_" + macWidgets.renderedRows[0].wid) : null;
}
Window {
    id: activityMirrorWindow
    width: 185; height: 185; visible: true; flags: Qt.Tool | Qt.WindowDoesNotAcceptFocus
    WidgetVisual {
        id: activityMirror; anchors.fill: parent; host: macWidgets; mirror: true
        readonly property var row: macWidgets.renderedRows[0] || null
        instanceId: row ? row.wid : ""; wtype: "activity"; wstyle: "normal"
        sname: row ? row.woutput : ""; wactivity: row ? row.wactivity : "{}"
        renderActive: !!row && macWidgets.outputActive(sname)
    }
}
Timer {
    interval: 200; repeat: true; running: true
    onTriggered: {
        if (++activityWaits > 240) { console.error("ACTIVITY_WIDGET_FAIL timeout phase " + activityPhase); Qt.exit(1); return; }
        if (!macBar.settingsReady || !macDock.settingsReady || !macWidgets.ready || macWidgets.pending) return;
        try {
            var phase = activityPhase, stats = macBar.stats, state = macWidgets.resourceState();
            if (phase === 0) {
                activityCheck(!stats.enabled && macBar.statsConsumers === 0, "no sampler without a view");
                activityOutput = macWidgets.displayChoices[0].name;
                activityCheck(macWidgets.addWidget("activity", "normal", "small", activityOutput), "add Small");
            } else if (phase === 1) {
                activityCheck(macWidgets.addWidget("activity", "liquid", "medium", activityOutput), "add Medium");
            } else if (phase === 2) {
                activityCheck(macWidgets.addWidget("activity", "normal", "large", activityOutput), "add Large");
            } else if (phase === 3) {
                if (stats.stale || typeof stats.sample.cpu !== "number") return;
                activityCheck(!macBar.barEnabled && macBar.statsConsumers === 0, "bar is disabled");
                activityCheck(state.sources.stats === 3 && state.consumers.length === 3 && state.activeViews >= 4, "desktop and mirror share per-ID consumers");
                activityPid = stats.testProcessId; activityCheck(activityPid > 0, "one real sampler started");
                var row = macWidgets.instanceRows[0], draft = JSON.parse(JSON.stringify(row.savedSettings));
                draft.activity = {metrics: ["memory", "network"], view: "graphs", future: {keep: false}};
                activityCheck(macWidgets.commitWidgetAppearance(row.id, draft, row.savedSettings, "activity"), "atomic metrics Apply");
            } else if (phase === 4) {
                var visual = activityVisual();
                activityCheck(visual && visual.visual.settings.view === "graphs" && visual.visual.shownMetrics.join() === "memory,network", "desktop applies local metrics");
                activityCheck(activityMirror.visual.shownMetrics.join() === "memory,network", "mirror has the same local metrics");
                var row = macWidgets.instanceRows[0];
                activityCheck(!macWidgets.commitWidgetAppearance(row.id, {activity: {metrics: []}}, row.savedSettings, "activity"), "invalid metrics rejected");
                activityCheck(!macWidgets.commitWidgetAppearance(row.id, row.savedSettings, {}, "activity"), "stale editor rejected");
                activityCheck(macWidgets.duplicateWidget(row.id), "duplicate Activity");
            } else if (phase === 5) {
                activityCheck(state.sources.stats === 4 && stats.testProcessId === activityPid, "four cards still use the same sampler");
                activityCopy = macWidgets.instanceRows[1].id;
                activityCheck(macWidgets.instanceRows[1].savedSettings.activity.future.keep === false, "duplicate retains unknown fields");
                activityCheck(macWidgets.removeWidget(activityCopy), "remove duplicate");
            } else if (phase === 6) {
                var visual = activityVisual(), button = activityFind(visual, "activityOpen");
                activityCheck(button && button.enabled, "interactive Activity");
                activityEvents.mouseClick(button, 30, 30, Qt.LeftButton, Qt.NoModifier, 0);
            } else if (phase === 7) {
                activityCheck(macBar.activeControl === "stats" && macBar.popupOwner === activityOutput, "details opens on the card's output with bar disabled");
                activityCheck(macWidgets.setWidgetsEnabled(false), "disable cards");
            } else if (phase === 8) {
                activityCheck(state.sources.stats === 0 && stats.enabled, "open details retains shared sampler without cards");
                macBar.controlRequested("close-stats");
            } else if (phase === 9) {
                if (stats.testProcessId) return;
                activityCheck(!stats.enabled && stats.stale && state.sources.stats === 0, "last view stops sampler");
                activityCheck(macWidgets.setWidgetsEnabled(true), "enable cards");
            } else if (phase === 10) {
                if (stats.stale || typeof stats.sample.cpu !== "number") return;
                activityCheck(state.sources.stats === 3 && stats.testProcessId !== activityPid, "resume restarts one sampler");
                activityHeldTime = activityVisual().activityData.sample.time;
                macWidgets.visibilityConnected = true; macWidgets.overviewOpen = false;
                macWidgets.visibilityClients = [{output: activityOutput, geometryKnown: true, fullscreen: 1, workspaceActive: true, mapped: true, hidden: false}];
            } else if (phase === 11) {
                if (stats.testProcessId) return;
                activityCheck(!stats.enabled && state.sources.stats === 0, "fullscreen releases Activity source");
                activityCheck(activityVisual().activityData.sample.time === activityHeldTime && activityMirror.activityData.sample.time === activityHeldTime, "culled visuals keep their snapshot");
                macWidgets.overviewOpen = true;
            } else if (phase === 12) {
                if (stats.stale || typeof stats.sample.cpu !== "number") return;
                activityCheck(stats.enabled && state.sources.stats === 3 && activityVisual().activityData.sample.time > activityHeldTime, "overview restores fresh data");
                activityCheck(stats.history.length <= 61 && stats.history.every(item => stats.sample.time - item.time <= 60), "history remains bounded to 60 seconds");
                stats.clock = stats.lastSample + 30000;
                activityCheck(stats.stale && activityVisual().visual.stale, "stale sample reaches desktop");
                stats.clock = Date.now();
                macWidgets.visibilityClients = []; macWidgets.overviewOpen = false;
                activityCheck(macWidgets.setWidgetsEnabled(false), "final release");
            } else if (phase === 13) {
                if (stats.testProcessId) return;
                activityCheck(!stats.enabled && state.sources.stats === 0, "final source and helper released");
                console.log("MACSHELL_ACTIVITY_WIDGET_PASS: S/M/L, metrics Apply/conflict, mirror/duplicate sharing, disabled bar, details output, disable/enable, fullscreen/overview, stale data and bounded history"); Qt.quit(); return;
            }
            activityPhase++;
        } catch (error) { console.error(error); Qt.exit(1); }
    }
}

// Injected into an isolated full shell with its own Clock store.
property int timerWidgetPhase: 0
property int timerWidgetWaits: 0
property string timerWidgetOutput: ""
property string timerWidgetFirst: ""
property string timerWidgetSecond: ""
property string timerWidgetSession: ""
property string timerWidgetEvent: ""
property var timerWidgetPoint: null
TestEvent { id: timerWidgetEvents }
function timerWidgetCheck(value, reason) { if (!value) throw new Error("TIMER_WIDGET_FAIL phase " + timerWidgetPhase + ": " + reason); }
function timerWidgetFind(item, name) {
    if (!item) return null;
    if (item.objectName === name) return item;
    for (var child of item.children || []) { var found = timerWidgetFind(child, name); if (found) return found; }
    return null;
}
function timerWidgetVisual(id) {
    var window = macWidgets.desktopWindows[timerWidgetOutput];
    return window ? timerWidgetFind(window.contentItem, "widgetVisual_" + id) : null;
}
function timerWidgetClick(id, name) {
    var visual = timerWidgetVisual(id), button = timerWidgetFind(visual, name);
    timerWidgetCheck(button && button.visible && button.enabled, "interactive " + name);
    timerWidgetEvents.mouseClick(button, button.width / 2, button.height / 2, Qt.LeftButton, Qt.NoModifier, 0);
}
Timer {
    interval: 200; repeat: true; running: true
    onTriggered: {
        if (++timerWidgetWaits > 220) { console.error("TIMER_WIDGET_FAIL timeout phase " + timerWidgetPhase); Qt.exit(1); return; }
        if (!macWidgets.ready || macWidgets.pending || !clockApp.backend.ready || clockApp.backend.busy) return;
        try {
            var backend = clockApp.backend, state = backend.timing && backend.timing.timer;
            if (!state || backend.timerStatus !== "normal") return;
            if (timerWidgetPhase === 0) {
                timerWidgetOutput = macWidgets.displayChoices[0].name;
                timerWidgetCheck(macWidgets.addWidget("timer", "normal", "small", timerWidgetOutput), "add first");
            } else if (timerWidgetPhase === 1) {
                timerWidgetFirst = macWidgets.instanceRows[0].id;
                timerWidgetCheck(macWidgets.addWidget("timer", "normal", "medium", timerWidgetOutput), "add second");
            } else if (timerWidgetPhase === 2) {
                timerWidgetSecond = macWidgets.instanceRows[1].id;
                if (!timerWidgetVisual(timerWidgetFirst) || !timerWidgetVisual(timerWidgetSecond)) return;
                timerWidgetCheck(timerWidgetVisual(timerWidgetFirst).visual.backend === backend && timerWidgetVisual(timerWidgetSecond).visual.backend === backend, "same backend");
                var surface = macWidgets.desktopWindows[timerWidgetOutput].contentItem;
                var registry = timerWidgetFind(surface, "widgetInputs"), visual = timerWidgetVisual(timerWidgetFirst);
                timerWidgetPoint = visual.mapToItem(surface, visual.width / 2, visual.height / 2);
                timerWidgetCheck(registry && registry.accepts(timerWidgetPoint.x, timerWidgetPoint.y), "desktop input mask covers timer card");
                timerWidgetClick(timerWidgetFirst, "timerWidgetPreset_0");
            } else if (timerWidgetPhase === 3) {
                if (state.state !== "running") return;
                timerWidgetSession = state.sessionId;
                timerWidgetCheck(timerWidgetVisual(timerWidgetSecond).visual.timer.sessionId === timerWidgetSession, "second view follows start");
                timerWidgetClick(timerWidgetSecond, "timerWidgetToggle");
            } else if (timerWidgetPhase === 4) {
                if (state.state !== "paused") return;
                timerWidgetCheck(clockApp.timer.state === "paused", "Clock follows widget pause");
                timerWidgetCheck(clockApp.resumeTimer(), "Clock resumes shared timer");
            } else if (timerWidgetPhase === 5) {
                if (state.state !== "running") return;
                timerWidgetClick(timerWidgetFirst, "timerWidgetPreset_1");
                timerWidgetCheck(timerWidgetVisual(timerWidgetFirst).visual.requestedMinutes === 15, "replacement needs confirmation");
                timerWidgetCheck(state.sessionId === timerWidgetSession, "not replaced yet");
                timerWidgetClick(timerWidgetFirst, "timerWidgetReplace");
            } else if (timerWidgetPhase === 6) {
                if (state.sessionId === timerWidgetSession) return;
                timerWidgetCheck(state.state === "running" && state.totalMs === 900000, "replacement committed once");
                timerWidgetClick(timerWidgetSecond, "timerWidgetCancel");
            } else if (timerWidgetPhase === 7) {
                if (state.state !== "idle") return;
                timerWidgetCheck(macWidgets.removeWidget(timerWidgetFirst), "remove first");
            } else if (timerWidgetPhase === 8) {
                var surface = macWidgets.desktopWindows[timerWidgetOutput].contentItem;
                timerWidgetCheck(!timerWidgetFind(surface, "widgetInputs").accepts(timerWidgetPoint.x, timerWidgetPoint.y), "removed card releases input mask");
                timerWidgetCheck(macWidgets.removeWidget(timerWidgetSecond), "remove second");
            } else if (timerWidgetPhase === 9) {
                timerWidgetCheck(clockApp.startTimer(1200, "", "silence"), "timer runs without widgets");
            } else if (timerWidgetPhase === 10) {
                if (state.state !== "idle" || !backend.completion) return;
                timerWidgetEvent = backend.completion.eventId;
            } else if (timerWidgetPhase === 11) {
                timerWidgetCheck(backend.completion.eventId === timerWidgetEvent && (!backend.timing.completionQueue || backend.timing.completionQueue.length === 0), "one completion after removing cards");
                timerWidgetCheck(backend.eventAction("dismiss-event"), "dismiss test event");
            } else if (timerWidgetPhase === 12) {
                if (backend.completion) return;
                console.log("TIMER_WIDGET_NATIVE_PASS: shared service, two cards, Clock controls, confirmed replacement and completion without cards"); Qt.quit(); return;
            }
            timerWidgetPhase++;
        } catch (error) { console.error(error); Qt.exit(1); }
    }
}

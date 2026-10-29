// Inserted into shell.qml after imports; uses its real components and fresh settings.
property int themePhase: 0
property int themeWaits: 0
property int themeCaptures: 0
property int oldToneEpoch: 0
property var retainedPane: null
property var appearancePane: null
property string appearanceToken: ""
property double retainedTimerEnd: 0
property string retainedAlarmId: ""
TestEvent { id: themeEvents }
function themeFind(item, name) {
    if (!item) return null;
    if (item.objectName === name) return item;
    for (var child of item.children || []) { var result = themeFind(child, name); if (result) return result; }
    return null;
}
function themeCheck(value, reason) { if (!value) throw new Error("THEME_NATIVE_FAIL phase " + themePhase + ": " + reason); }
function themeAll(dark) {
    themeCheck(macBar.darkMode === dark && macDock.darkMode === dark, "shared theme");
    themeCheck(clockApp.darkMode === dark && macWidgets.darkGlass === dark, "Clock and desktop theme");
    themeCheck(macBar.dk === (dark ? 1 : 0), "ink switches atomically");
    themeCheck(macBar.testPalette.dark === dark, "popover palette");
    if (!macBar.testInk.active) themeCheck(macBar.testBarPalette.dark === dark, "opaque bar palette");
    function checkGlyphs(item) {
        if (!item) return;
        if (item.parent && item.parent.on === false && item.parent.t && typeof item.kind === "string" && item.color !== undefined)
            themeCheck(String(item.color) === String(item.parent.t.fg), "off-state glyph must change with its material");
        for (var child of item.children || []) checkGlyphs(child);
    }
    checkGlyphs(macBar.testCc);
}
function themeGrab(item, name) {
    themeCaptures++;
    item.grabToImage(result => {
        themeCheck(result.saveToFile(Quickshell.env("MACSHELL_THEME_CAPTURE") + "/" + name + ".png"), "save " + name);
        themeCaptures--;
    });
}
function themeMenuToggle() { macBar.menuModelFor("view").find(entry => entry.label === "Dark Mode").run(); }
PanelWindow {
    id: themeBarBackdrop
    anchors {left: true; right: true; top: true}
    implicitHeight: macBar.barHeight; color: "#141414"
    exclusionMode: ExclusionMode.Ignore; mask: Region {}
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    WlrLayershell.namespace: "macshell-theme-guard"
}
Window {
    id: themeCards
    width: 856; height: 292
    minimumWidth: 856; maximumWidth: 856; minimumHeight: 292; maximumHeight: 292
    flags: Qt.Tool | Qt.WindowDoesNotAcceptFocus
    visible: true; color: macDock.darkMode ? "#25262c" : "#f3f4f8"
    Rectangle { anchors.fill: parent; color: themeCards.color }
    Text { x: 24; y: 18; text: macDock.darkMode ? "Dark appearance" : "Light appearance"; color: macDock.darkMode ? "white" : "#1d1d1f"; font.pixelSize: 18 }
    Row {
        x: 24; y: 58; spacing: 22
        Repeater {
            model: ["weather", "calendar", "clock", "player"]
            WidgetPreview {
                required property string modelData
                widgetType: modelData; widgetStyle: "liquid"; widgetSize: "small"
                dark: macDock.darkMode; width: 185; height: 185
            }
        }
    }
    Text { x: 24; y: 260; text: "Shared theme · demonstration data"; color: macDock.darkMode ? "#b9bac3" : "#585962"; font.pixelSize: 12 }
}
QtObject { id: appearanceDemo; property bool settingsEditable: true }
Window {
    id: appearanceExample
    width: 580; height: themePhase >= 39 ? 640 : 740
    minimumWidth: 580; maximumWidth: 580; minimumHeight: height; maximumHeight: height
    flags: Qt.Tool | Qt.WindowDoesNotAcceptFocus
    visible: (themePhase >= 29 && themePhase <= 34) || (themePhase >= 39 && themePhase <= 42)
    color: macDock.darkMode ? "#1e1e1e" : "#f5f5f7"
    Rectangle { anchors.fill: parent; color: appearanceExample.color }
    WidgetAppearanceEditor {
        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 24
        controller: appearanceDemo; foreground: macDock.darkMode ? "#f5f5f7" : "#1d1d1f"
        record: themePhase >= 39 ? ({id: "clock-sample", type: "clock", size: "small", style: "liquid", defaultStyle: "liquid", mode: "auto", supported: true,
            savedSettings: {style: "liquid", appearance: {secondsMode: "tick"}}})
            : ({id: "sample", type: "player", size: "medium", style: "liquid", defaultStyle: "liquid", mode: "auto", supported: true,
                savedSettings: {style: "liquid", appearance: {fontFamily: "Noto Sans", textScale: 1.2, density: "comfortable", tint: "#3d907b"}}})
    }
}
Timer {
    interval: 650; repeat: true; running: true
    onTriggered: {
        if (themeCaptures) return;
        if (macWidgets.pending) return;
        if (!macBar.settingsReady || !macDock.settingsReady || !macBar.testUi || !macWidgets.ready) {
            if (++themeWaits > 20) { console.error("THEME_NATIVE_FAIL startup timeout"); Qt.exit(1); }
            return;
        }
        try {
            var settings = macDock.testWindow(), phase = themePhase;
            if (phase === 0) {
                themeAll(false); macBar.autoContrast = false;
                macBar.ccControls = macBar.ccDefault.concat(["darkmode"]);
                macDock.openPrefs("appearance");
            } else if (phase === 1) {
                var dark = themeFind(settings.contentItem, "appearanceDark"); themeCheck(dark, "Settings dark tile");
                themeEvents.mouseClick(dark, 40, 30, Qt.LeftButton, Qt.NoModifier, 0); themeAll(true);
                oldToneEpoch = macBar.toneEpoch; macBar.bgTone = 1;
                var light = themeFind(settings.contentItem, "appearanceLight");
                themeEvents.mouseClick(light, 40, 30, Qt.LeftButton, Qt.NoModifier, 0); themeAll(false);
                macBar.autoContrast = true;
                themeCheck(!macBar.acceptTone(oldToneEpoch + " 1"), "late tone ignored after theme switch");
                themeCheck(macBar.acceptTone(macBar.toneEpoch + " 0"), "current background sample accepted");
                themeCheck(!macBar.effDark, "dark background keeps readable light material");
                macBar.autoContrast = false; macBar.ccRequest(true);
            } else if (phase === 2) {
                themeAll(false);
                themeGrab(settings.contentItem, "theme-settings-light");
                themeGrab(macBar.testCc, "theme-controls-light");
                themeGrab(themeCards.contentItem, "theme-widgets-light");
            } else if (phase === 3) {
                var button = themeFind(macBar.testCc, "ccTheme"); themeCheck(button, "CC theme button");
                themeEvents.mouseClick(button, button.width / 2, button.height / 2, Qt.LeftButton, Qt.NoModifier, 0);
                themeAll(true);
            } else if (phase === 4) {
                themeGrab(settings.contentItem, "theme-settings-dark");
                themeGrab(macBar.testCc, "theme-controls-dark");
                themeGrab(themeCards.contentItem, "theme-widgets-dark");
            } else if (phase === 5) {
                themeMenuToggle(); themeAll(false); macBar.ccRequest(false);
            } else if (phase >= 6 && phase <= 11) {
                var index = Math.floor((phase - 6) / 2), panes = ["barlayout", "activity", "widgets"], names = ["settingsBarLayout", "settingsActivity", "settingsWidgets"];
                if (phase % 2 === 0) macDock.openPrefs(panes[index]);
                else {
                    retainedPane = themeFind(settings.contentItem, names[index]); themeCheck(retainedPane, "live settings pane " + panes[index]);
                    themeCheck(retainedPane.foreground.r < .2, "light pane ink");
                    themeMenuToggle(); themeAll(true); themeCheck(retainedPane.foreground.r > .9, "already open pane follows dark");
                    themeMenuToggle(); themeAll(false); themeCheck(retainedPane.foreground.r < .2, "already open pane follows light");
                }
            } else if (phase === 12) {
                macDock.testWindow().hide(); clockApp.open(); themeAll(false);
            } else if (phase === 13) {
                themeGrab(clockApp.testWindow().contentItem, "theme-clock-light");
                themeMenuToggle(); themeAll(true);
            } else if (phase === 14) {
                themeGrab(clockApp.testWindow().contentItem, "theme-clock-dark");
                themeMenuToggle(); themeAll(false);
            } else if (phase === 15) {
                clockApp.testWindow().hide();
                macBar.autoContrast = true; macBar.barGlass = false; macBar.barBgOpacity = 0;
            } else if (phase === 16) {
                themeAll(false);
                themeCheck(macBar.testInk.sampled && macBar.testBarPalette.dark, "transparent light bar uses light ink over a dark background");
                var oldInkEpoch = macBar.testInk.epoch;
                themeBarBackdrop.color = "white"; macBar.testInk.schedule();
                themeCheck(!macBar.testInk.accept(oldInkEpoch + " 1 1 1"), "old output sample cannot recolour the bar");
            } else if (phase === 17) {
                themeCheck(!macBar.testBarPalette.dark, "transparent bar uses dark ink over a white background");
                themeMenuToggle(); themeAll(true);
                themeCheck(!macBar.testBarPalette.dark, "theme changes preserve readable ink on a transparent bar");
                themeBarBackdrop.color = "#141414"; macBar.testInk.schedule();
            } else if (phase === 18) {
                themeCheck(macBar.testBarPalette.dark, "dark background restores light ink");
                themeMenuToggle(); themeAll(false);
            } else if (phase === 19) {
                // Keep every instance action visible in the public Settings captures.
                settings.minimumHeight = 720; settings.maximumHeight = 720; settings.height = 720;
                themeCheck(macWidgets.addWidget("clock", "dark", "small"), "create isolated clock instance");
            } else if (phase === 20) {
                themeCheck(macWidgets.addWidget("calendar", "normal", "small"), "create isolated calendar instance");
            } else if (phase === 21) {
                macWidgets.editing = true; macWidgets.selectWidget(macWidgets.instanceRows[1].id); macWidgets.editControls.openActions();
            } else if (phase === 22) {
                var configure = macWidgets.editControls.contentItem.actionButton("widgetEditConfigure");
                themeCheck(configure && configure.visible && configure.enabled && macWidgets.editControls.active, "Configure available only for selected Edit card");
                themeEvents.mouseClick(configure, configure.width / 2, configure.height / 2, Qt.LeftButton, Qt.NoModifier, 0);
            } else if (phase === 23) {
                var gallery = themeFind(settings.contentItem, "settingsWidgets"), editor = themeFind(gallery, "widgetInstances");
                themeCheck(gallery && !gallery.adding && editor.selected.id === macWidgets.instanceRows[1].id, "Configure opens Settings at the selected instance");
                themeGrab(settings.contentItem, "theme-widget-instances-light");
            } else if (phase === 24) {
                themeMenuToggle(); themeAll(true);
            } else if (phase === 25) {
                themeGrab(settings.contentItem, "theme-widget-instances-dark");
            } else if (phase === 26) {
                themeMenuToggle(); themeAll(false); macWidgets.finishEditing(false); settings.hide();
            } else if (phase === 27) {
                themeCheck(macWidgets.setStyle(macWidgets.instanceRows[0].id, "liquid"), "prepare liquid theme inheritance");
            } else if (phase === 28) {
                macDock.openWidgetPrefs(macWidgets.instanceRows[0].id);
            } else if (phase === 29) {
                var instances = themeFind(settings.contentItem, "widgetInstances"); instances.appearanceExpanded = true;
                appearancePane = themeFind(instances, "widgetAppearanceEditor");
                appearanceToken = macWidgets.preferences.token;
                appearancePane.change("theme", "light"); appearancePane.change("fontFamily", "monospace"); appearancePane.change("textScale", 1.2);
                themeCheck(macWidgets.preferences.token === appearanceToken && appearancePane.dirty, "draft and preview make no write");
            } else if (phase === 30) {
                themeGrab(appearancePane, "theme-widget-appearance-light");
                themeGrab(appearanceExample.contentItem, "theme-player-appearance-light");
            } else if (phase === 31) {
                appearancePane.apply();
            } else if (phase === 32) {
                var card = themeFind(macWidgets.desktopWindow.contentItem, "widgetVisual_" + macWidgets.instanceRows[0].id);
                var mirror = themeFind(macBar.testUi, "widgetMirror_" + macWidgets.instanceRows[0].id);
                themeCheck(card && mirror && card.visual.fam === "monospace" && mirror.visual.fam === "monospace", "desktop and glass mirror use local font");
                themeCheck(card.visual.textScale === 1.2 && !card.visual.dark && !mirror.visual.dark, "desktop and mirror use applied appearance");
                themeCheck(!appearancePane.dirty, "Apply completes draft");
                themeMenuToggle(); themeAll(true);
            } else if (phase === 33) {
                var card = themeFind(macWidgets.desktopWindow.contentItem, "widgetVisual_" + macWidgets.instanceRows[0].id);
                var sibling = themeFind(macWidgets.desktopWindow.contentItem, "widgetVisual_" + macWidgets.instanceRows[1].id);
                themeCheck(!card.visual.dark && sibling.visual.dark, "shell theme changes only inheriting cards");
                themeGrab(appearancePane, "theme-widget-appearance-dark"); macDock.setLook("fontFamily", "Noto Sans");
                themeGrab(appearanceExample.contentItem, "theme-player-appearance-dark");
            } else if (phase === 34) {
                var card = themeFind(macWidgets.desktopWindow.contentItem, "widgetVisual_" + macWidgets.instanceRows[0].id);
                var sibling = themeFind(macWidgets.desktopWindow.contentItem, "widgetVisual_" + macWidgets.instanceRows[1].id);
                themeCheck(card.visual.fam === "monospace" && sibling.visual.fam === "Noto Sans", "shell font changes only inheriting cards");
                appearancePane.change("all", null); appearancePane.apply();
            } else if (phase === 35) {
                var card = themeFind(macWidgets.desktopWindow.contentItem, "widgetVisual_" + macWidgets.instanceRows[0].id);
                var mirror = themeFind(macBar.testUi, "widgetMirror_" + macWidgets.instanceRows[0].id);
                themeCheck(card.visual.dark && mirror.visual.dark && card.visual.fam === "Noto Sans" && card.visual.textScale === 1, "Reset restores shell theme/font in both renderers");
                themeMenuToggle(); themeAll(false); settings.hide();
            } else if (phase === 36) {
                clockApp.startTimer(60000, "Isolated widget lifecycle check"); retainedTimerEnd = clockApp.timer.endAt;
                var future = new Date(Date.now() + 7200000);
                clockApp.addAlarm(future.getHours(), future.getMinutes(), "Isolated widget lifecycle check", []);
                retainedAlarmId = clockApp.alarms.find(alarm => alarm.label === "Isolated widget lifecycle check").id;
                themeCheck(macWidgets.setWidgetsEnabled(false), "disable widgets while ClockApp owns a timer and alarm");
            } else if (phase === 37) {
                themeCheck(!macWidgets.widgetsEnabled && macWidgets.resourceState().views === 0 && !macWidgets.clockSource.running, "global switch releases desktop and mirror clocks");
                themeCheck(clockApp.timer.state === "running" && clockApp.timer.endAt === retainedTimerEnd, "hidden widgets preserve timer deadline");
                themeCheck(clockApp.alarms.some(alarm => alarm.id === retainedAlarmId && alarm.on), "hidden widgets preserve enabled alarm");
                themeCheck(macWidgets.setWidgetsEnabled(true), "re-enable saved widgets");
            } else if (phase === 38) {
                themeCheck(macWidgets.clockSource.running && macWidgets.resourceState().views > 0, "visible clocks resume");
                themeCheck(clockApp.timer.state === "running" && clockApp.timer.endAt === retainedTimerEnd, "re-enabling widgets keeps timer deadline");
                clockApp.cancelTimer(); clockApp.deleteAlarm(retainedAlarmId);
                themeCheck(macWidgets.setWidgetAppearance(macWidgets.instanceRows.find(row => row.type === "clock").id, "secondsMode", "tick"), "apply tick mode to native Clock");
            } else if (phase === 39) {
                themeCheck(macWidgets.clockSource.precision === "tick", "desktop and mirror share one second clock");
                themeGrab(appearanceExample.contentItem, "theme-clock-appearance-light");
            } else if (phase === 40) {
                themeMenuToggle(); themeAll(true);
                themeCheck(macWidgets.setWidgetAppearance(macWidgets.instanceRows.find(row => row.type === "clock").id, "secondsMode", "hidden"), "hide seconds on native Clock");
            } else if (phase === 41) {
                var clock = themeFind(macWidgets.desktopWindow.contentItem, "widgetVisual_" + macWidgets.instanceRows.find(row => row.type === "clock").id);
                themeCheck(macWidgets.clockSource.precision === "minute" && clock.visual.secs === 0, "hidden seconds keep minute/date updates");
                themeGrab(appearanceExample.contentItem, "theme-clock-appearance-dark");
            } else if (phase === 42) {
                themeMenuToggle(); themeAll(false);
                themeCheck(macWidgets.resetWidgetAppearance(macWidgets.instanceRows.find(row => row.type === "clock").id, "secondsMode"), "restore smooth default");
            } else if (phase === 43) {
                themeCheck(macWidgets.clockSource.precision === "smooth", "smooth default resumes without a separate card timer");
                console.log("MACSHELL_THEME_NATIVE_PASS: Settings/CC/menu, persistence, live panes/Clock/widgets, stale tone, atomic glyphs and transparent bar contrast on owned light/dark surfaces"); Qt.quit();
            }
            themePhase++;
        } catch (error) { console.error(error); Qt.exit(1); }
    }
}

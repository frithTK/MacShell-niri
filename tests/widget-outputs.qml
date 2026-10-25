import QtQuick
import Quickshell
import "." as Port
import "WidgetLayout.js" as Layout
import "WidgetAppearance.js" as Appearance

// Controller/writer integration with synthetic logical outputs; no desktop surfaces.
ShellRoot {
    id: root
    property int phase: 0
    property string initialToken: ""
    property string desired: ""
    property string movedId: ""
    property string copyId: ""
    property string deletedRecord: ""
    property string futureRecord: ""
    property var appearanceBaseline: ({})
    property var appearanceDraft: ({})
    Port.WidgetPreferences { id: other; origin: widgets.origin }
    QtObject { id: one; property string name: "DP-1"; property real width: 1920; property real height: 1080 }
    QtObject { id: two; property string name: "DP-2"; property real width: 1280; property real height: 720 }
    QtObject { id: three; property string name: "HDMI-1"; property real width: 1280; property real height: 800 }
    QtObject { id: bar; property bool settingsReady: true; property bool barEnabled: true; property int barHeight: 28 }
    QtObject {
        id: dock
        property bool settingsReady: true; property bool dockEnabled: true
        property string monitor: "DP-2"; property string hideMode: "never"
        property int bgHeight: 70; property int margin: 6
        property string fontFamily: "Sans"; property color accent: "#0a84ff"; property bool darkMode: true
        property real glassOpacity: .42; property real glassBlur: 5; property real glassLiquid: 1
        property real glassRim: .45; property real glassGrain: .03
    }
    QtObject {
        id: hub
        property var dock: dock; property var bar: bar
        property bool widgetsWantWallpaper: false; property var wallpaperMap: ({})
        function refreshWallpaper() {}
    }
    Port.MacWidgets {
        id: widgets; hub: hub
        screens: [one, two]
        outputs: [{name: "DP-1", serial: "one"}, {name: "DP-2", serial: "two"}]
    }
    function check(ok, reason) { if (!ok) throw new Error(reason); }
    function unchanged() {
        check(widgets.preferences.token === initialToken, "geometry must not write settings");
        check(JSON.stringify(widgets.preferences.values.widgets) === desired, "desired cells must be retained");
    }
    Timer {
        interval: 80; repeat: true; running: true
        onTriggered: {
            if (!widgets.ready || widgets.pending) return;
            try {
                if (root.phase === 0) {
                    root.check(widgets.widgetCount === 2 && widgets.rowsForOutput("DP-1").length === 1 && widgets.rowsForOutput("DP-2").length === 1, "two independently filtered outputs");
                    root.check(widgets.placementScreen("DP-2").area.height === 616, "Dock reserves only its own display");
                    root.initialToken = widgets.preferences.token; root.desired = JSON.stringify(widgets.preferences.values.widgets);
                    widgets.screens = [two, one]; root.phase++;
                } else if (root.phase === 1) {
                    root.unchanged(); root.check(widgets.rowsForOutput("DP-1")[0].wid === "a", "reorder keeps display identity");
                    widgets.editing = true; widgets.selectWidget("a");
                    root.check(widgets.selectedId === "a", "selection available");
                    bar.barHeight = 80; root.phase++;
                } else if (root.phase === 2) {
                    root.unchanged(); root.check(!widgets.editing, "reserved-area change safely finishes editing");
                    root.check(widgets.rowsForOutput("DP-1")[0].wy >= 104, "bar reserve reflows grid reactively");
                    one.width = 400; one.height = 300; root.phase++;
                } else if (root.phase === 3) {
                    root.unchanged(); root.check(widgets.rowsForOutput("DP-1").length === 0 && widgets.unplacedWidgets.length === 1, "small reserved display reports unplaced");
                    one.width = 1920; one.height = 1080; bar.barHeight = 28; widgets.screens = [two]; root.phase++;
                } else if (root.phase === 4) {
                    root.unchanged(); root.check(widgets.widgetCount === 1 && widgets.unplacedWidgets[0].id === "a", "disconnect retains only that display's cards");
                    root.check(widgets.editable, "another live display remains editable");
                    widgets.screens = [one, two]; root.phase++;
                } else if (root.phase === 5) {
                    root.unchanged(); root.check(widgets.rowsForOutput("DP-1")[0].wx === 42 + 8 * 207, "original desired slot restored");
                    root.check(widgets.addWidget("calendar", "normal", "small", "DP-2"), "explicit add to second display"); root.phase++;
                } else if (root.phase === 6) {
                    root.check(widgets.rowsForOutput("DP-1").length === 1 && widgets.rowsForOutput("DP-2").length === 2, "new instance not duplicated");
                    root.movedId = widgets.preferences.values.widgets[2].id;
                    root.check(widgets.preferences.values.widgets[2].output === "second", "correct saved profile for new instance");
                    widgets.editing = true; widgets.selectWidget(root.movedId);
                    root.check(widgets.editingOutput === "DP-2", "controls follow selected output");
                    root.check(widgets.moveWidgetToOutput(root.movedId, "DP-1"), "move between displays"); root.phase++;
                } else if (root.phase === 7) {
                    root.check(widgets.selectedId === "", "move invalidates selection geometry");
                    root.check(widgets.rowsForOutput("DP-1").length === 2 && widgets.rowsForOutput("DP-2").length === 1, "move removes old output row");
                    root.check(widgets.preferences.values.widgets[2].output === "main", "move commits destination profile");
                    root.initialToken = widgets.preferences.token; two.width = 100; two.height = 100; root.phase++;
                } else if (root.phase === 8) {
                    root.check(!widgets.moveWidgetToOutput(root.movedId, "DP-2"), "full display refuses move");
                    root.check(!widgets.addWidget("clock", "dark", "small", "DP-2"), "full display refuses add");
                    root.check(widgets.preferences.token === root.initialToken && widgets.preferences.values.widgets[2].output === "main", "failed move keeps original record");
                    two.width = 1280; two.height = 720;
                    root.check(widgets.setSize(root.movedId, "medium"), "resize uses instance output"); root.phase++;
                } else if (root.phase === 9) {
                    root.check(widgets.rowsForOutput("DP-1").find(row => row.wid === root.movedId).wsize === "medium", "size changed only at destination");
                    root.check(widgets.preferences.values.widgets[1].settings.size === "small", "second output unchanged by resize");
                    widgets.finishEditing(false);
                    widgets.screens = [one, two, three]; widgets.outputs = widgets.outputs.concat([{name: "HDMI-1", serial: "three"}]); root.phase++;
                } else if (root.phase === 10) {
                    root.check(widgets.moveWidgetToOutput(root.movedId, "HDMI-1"), "explicit transfer creates profile on a new display"); root.phase++;
                } else if (root.phase === 11) {
                    var profile = widgets.preferences.values.widgets[2].output;
                    root.check(widgets.preferences.values.outputs[profile].identity.serial === "three", "new profile identity persisted");
                    root.check(widgets.preferences.values.bindings["HDMI-1"] === profile && widgets.preferences.values.desktopOutput === "main", "new binding keeps legacy default");
                    root.check(widgets.rowsForOutput("HDMI-1").length === 1 && widgets.rowsForOutput("DP-1").length === 1, "new profile renders only on its destination");
                    root.phase++;
                } else if (root.phase === 12) {
                    var next = Layout.clone(widgets.preferences.values);
                    next.widgets[0].settings.custom = {tags: [false, {value: "retained"}]};
                    next.widgets[0].position.snap = false;
                    next.widgets[0].extension = [0, false];
                    var future = {id: "future", type: "agenda", version: 99, custom: {retained: [0, false]}};
                    root.futureRecord = JSON.stringify(future); next.widgets.push(future);
                    root.check(widgets.preferences.save(next), "seed unknown fields"); root.phase++;
                } else if (root.phase === 13) {
                    widgets.setEditorOpen("settings", true);
                    root.futureRecord = JSON.stringify(widgets.preferences.values.widgets.find(item => item.id === "future"));
                    root.check(widgets.instanceRows.length === 4 && !widgets.instanceRows[3].supported, "list includes future records");
                    root.check(widgets.duplicateWidget("a"), "duplicate accepted"); root.phase++;
                } else if (root.phase === 14) {
                    var records = widgets.preferences.values.widgets, copy = records[1]; root.copyId = copy.id;
                    root.check(records.length === 5 && copy.id !== "a" && copy.type === "clock", "duplicate gets a fresh ID next to its source");
                    root.check(copy.settings.custom.tags[1].value === "retained" && copy.position.snap === false, "duplicate keeps nested and unknown fields");
                    root.check(widgets.setStyle(copy.id, "light"), "configure duplicate"); root.phase++;
                } else if (root.phase === 15) {
                    var records = widgets.preferences.values.widgets;
                    root.check(records[0].settings.style === "dark" && records[1].settings.style === "light", "duplicate style is independent");
                    root.check(records[0].settings !== records[1].settings && records[0].settings.custom !== records[1].settings.custom, "no shared nested settings");
                    one.width = 100; one.height = 100; root.phase++;
                } else if (root.phase === 16) {
                    root.initialToken = widgets.preferences.token;
                    root.check(!widgets.duplicateWidget("a") && !widgets.setSize("a", "large"), "no-room duplicate and resize refused");
                    root.check(widgets.preferences.token === root.initialToken && widgets.preferences.values.widgets.length === 5, "no-room retains every card");
                    one.width = 1920; one.height = 1080;
                    root.deletedRecord = JSON.stringify(widgets.preferences.values.widgets[1]);
                    widgets.editError = "Previous placement failure";
                    root.check(widgets.removeWidget(root.copyId), "remove duplicate");
                    root.check(!widgets.canUndoDelete, "undo waits for successful commit"); root.phase++;
                } else if (root.phase === 17) {
                    root.check(widgets.canUndoDelete, "successful removal offers undo");
                    root.check(widgets.editError === "", "successful action clears an earlier placement error");
                    root.check(widgets.setWeather("tempUnit", "F"), "unrelated setting change"); root.phase++;
                } else if (root.phase === 18) {
                    root.check(widgets.undoDelete(), "undo merges current settings"); root.phase++;
                } else if (root.phase === 19) {
                    root.check(JSON.stringify(widgets.preferences.values.widgets[1]) === root.deletedRecord && widgets.tempUnit === "F", "undo restores exact record and keeps unrelated setting");
                    root.check(!widgets.canUndoDelete, "successful undo consumes one entry");
                    root.check(widgets.removeWidget(root.copyId), "remove copy again"); root.phase++;
                } else if (root.phase === 20) {
                    root.check(widgets.removeWidget("a"), "multiple removals"); root.phase++;
                } else if (root.phase === 21) {
                    root.check(widgets.undoStack.length === 2, "each successful removal remembered");
                    widgets.screens = [two, three]; root.check(widgets.undoDelete(), "undo after disconnection"); root.phase++;
                } else if (root.phase === 22) {
                    root.check(widgets.instanceRows.find(item => item.id === "a").placed === false, "disconnected restored card remains in list");
                    root.check(widgets.undoDelete(), "undo second removal"); root.phase++;
                } else if (root.phase === 23) {
                    root.check(JSON.stringify(widgets.preferences.values.widgets[1]) === root.deletedRecord, "disconnected undo preserves position and settings");
                    root.check(widgets.moveWidgetToOutput(root.copyId, "DP-2"), "move an unplaced instance to a connected display"); root.phase++;
                } else if (root.phase === 24) {
                    root.check(widgets.instanceRows.find(item => item.id === root.copyId).placed, "unplaced instance rescued");
                    root.check(widgets.preferences.values.widgets.find(item => item.id === root.copyId).position.snap === false, "moving retains unknown position fields");
                    root.check(!widgets.setStyle("future", "normal") && !widgets.duplicateWidget("future"), "unknown instances cannot be reinterpreted");
                    root.check(widgets.removeWidget("future"), "explicit remove future record"); root.phase++;
                } else if (root.phase === 25) {
                    root.check(widgets.undoDelete(), "restore future record"); root.phase++;
                } else if (root.phase === 26) {
                    root.check(JSON.stringify(widgets.preferences.values.widgets.find(item => item.id === "future")) === root.futureRecord, "opaque record restored exactly");
                    other.refresh(); root.phase++;
                } else if (root.phase === 27) {
                    if (other.loading || !other.ready) return;
                    var next = Layout.clone(other.values); next.defaults.cityName = "Other writer";
                    root.check(other.save(next), "external writer commits"); root.phase++;
                } else if (root.phase === 28) {
                    if (other.pending) return;
                    root.check(widgets.removeWidget("a"), "stale deletion submitted"); root.phase++;
                } else if (root.phase === 29) {
                    root.check(widgets.error.indexOf("changed elsewhere") >= 0 && !widgets.canUndoDelete, "failed deletion creates no undo entry");
                    root.check(widgets.preferences.values.widgets.some(item => item.id === "a"), "conflicted removal retains card");
                    root.check(widgets.removeWidget("a"), "retry deletion against current state"); root.phase++;
                } else if (root.phase === 30) {
                    root.check(widgets.canUndoDelete, "retry deletion remembered"); other.refresh(); root.phase++;
                } else if (root.phase === 31) {
                    if (other.loading || !other.ready) return;
                    var next = Layout.clone(other.values); next.defaults.tempUnit = "C";
                    root.check(other.save(next), "external change before undo"); root.phase++;
                } else if (root.phase === 32) {
                    if (other.pending) return;
                    root.check(widgets.undoDelete(), "stale undo submitted"); root.phase++;
                } else if (root.phase === 33) {
                    root.check(widgets.error.indexOf("changed elsewhere") >= 0 && widgets.canUndoDelete, "failed undo retains history for retry");
                    root.check(widgets.undoDelete(), "retry undo against current values"); root.phase++;
                } else if (root.phase === 34) {
                    root.check(widgets.tempUnit === "C" && widgets.cityName === "Other writer", "undo preserves external writer changes");
                    root.check(widgets.preferences.values.widgets.some(item => item.id === "a") && !widgets.canUndoDelete, "retry restores ID exactly once");
                    root.check(widgets.removeWidget(root.copyId), "remove before closing editor");
                    widgets.setEditorOpen("settings", false); root.phase++;
                } else if (root.phase === 35) {
                    widgets.setEditorOpen("settings", true);
                    root.check(!widgets.canUndoDelete, "closing editor during save clears session history");
                    root.check(!widgets.removeWidget("missing"), "nonexistent record is not a successful removal");
                    var next = Layout.clone(widgets.preferences.values), card = next.widgets.find(item => item.id === "a");
                    card.settings.size = "large";
                    root.check(widgets.preferences.save(next), "seed large card");
                    widgets.screens = [one, two, three]; one.width = 400; one.height = 300; root.phase++;
                } else if (root.phase === 36) {
                    root.check(!widgets.instanceRows.find(item => item.id === "a").placed, "large card does not fit on connected tiny display");
                    root.check(widgets.setSize("a", "small"), "resize an unplaced card to fit"); root.phase++;
                } else if (root.phase === 37) {
                    root.check(widgets.instanceRows.find(item => item.id === "a").placed, "smaller unplaced card becomes visible");
                    root.check(widgets.removeWidget("a"), "remove before full-display undo"); root.phase++;
                } else if (root.phase === 38) {
                    one.width = 100; one.height = 100;
                    root.check(widgets.undoDelete(), "full-display undo keeps the restored record"); root.phase++;
                } else if (root.phase === 39) {
                    root.check(!widgets.instanceRows.find(item => item.id === "a").placed && !widgets.canUndoDelete, "full-display undo restores as unplaced without losing the card");
                    one.width = 1920; one.height = 1080;
                    root.check(widgets.setStyle("a", "liquid"), "prepare inherited theme style"); root.phase++;
                } else if (root.phase === 40) {
                    root.check(widgets.setWidgetAppearance("a", "theme", "light"), "set local theme"); root.phase++;
                } else if (root.phase === 41) {
                    root.check(widgets.setWidgetAppearance("a", "fontFamily", "monospace"), "set local font"); root.phase++;
                } else if (root.phase === 42) {
                    root.check(widgets.setWidgetAppearance("a", "textScale", 1.2), "set local text size"); root.phase++;
                } else if (root.phase === 43) {
                    root.initialToken = widgets.preferences.token;
                    root.check(!widgets.setWidgetAppearance("a", "density", "compact") && !widgets.setWidgetAppearance("a", "tint", "#377cc8"), "unsupported controls cannot mutate Clock");
                    root.check(!widgets.setWidgetAppearance("a", "textScale", 2) && !widgets.setWidgetAppearance("a", "textScale", true), "invalid text sizes rejected");
                    root.check(widgets.preferences.token === root.initialToken, "invalid appearance does not write");
                    var next = Layout.clone(widgets.preferences.values); next.defaults.mode = "dark";
                    next.widgets.find(item => item.id === "a").settings.appearance.extension = {keep: [false, 0]};
                    root.check(widgets.preferences.save(next), "retain future appearance fields"); root.phase++;
                } else if (root.phase === 44) {
                    root.check(widgets.duplicateWidget("a"), "duplicate local appearance"); root.phase++;
                } else if (root.phase === 45) {
                    root.copyId = widgets.preferences.values.widgets[1].id;
                    root.check(widgets.instanceRows.find(item => item.id === root.copyId).appearance.fontFamily === "monospace", "duplicate appearance retained");
                    root.check(widgets.setWidgetAppearance(root.copyId, "theme", "dark"), "change duplicate theme"); root.phase++;
                } else if (root.phase === 46) {
                    var source = widgets.preferences.values.widgets.find(item => item.id === "a");
                    root.check(source.settings.appearance.theme === "light", "duplicate theme is independent");
                    root.deletedRecord = JSON.stringify(source);
                    root.check(widgets.removeWidget("a"), "remove customized card"); root.phase++;
                } else if (root.phase === 47) {
                    root.check(widgets.undoDelete(), "undo customized card removal"); root.phase++;
                } else if (root.phase === 48) {
                    root.check(JSON.stringify(widgets.preferences.values.widgets.find(item => item.id === "a")) === root.deletedRecord, "Undo retains full appearance");
                    root.check(widgets.resetWidgetAppearance("a", "textScale"), "reset one field"); root.phase++;
                } else if (root.phase === 49) {
                    var look = widgets.instanceRows.find(item => item.id === "a").appearance;
                    root.check(look.textScale === undefined && look.fontFamily === "monospace" && look.theme === "light", "field reset keeps other overrides");
                    root.check(widgets.resetWidgetAppearance("a", "all"), "reset appearance to inherited defaults"); root.phase++;
                } else if (root.phase === 50) {
                    var card = widgets.instanceRows.find(item => item.id === "a");
                    root.check(card.styleInherited && card.appearance.theme === undefined && card.appearance.fontFamily === undefined && card.appearance.extension.keep[1] === 0, "reset keeps unknown fields and restores inheritance");
                    root.check(widgets.setMode(root.movedId, "dark"), "legacy calendar mode"); root.phase++;
                } else if (root.phase === 51) {
                    root.check(widgets.setWidgetAppearance(root.movedId, "theme", "light"), "new theme supersedes legacy mode"); root.phase++;
                } else if (root.phase === 52) {
                    root.check(widgets.resetWidgetAppearance(root.movedId, "theme"), "return legacy calendar to shell theme"); root.phase++;
                } else if (root.phase === 53) {
                    var card = widgets.instanceRows.find(item => item.id === root.movedId);
                    root.check(card.appearance.theme === "auto" && !Appearance.resolve(card.type, card.style, card.appearance, card.mode, "Sans", false, .8).dark, "Follow shell ignores explicit and inherited legacy dark mode");
                    var next = Layout.clone(widgets.preferences.values); next.defaults.styles.clock = "liquid";
                    root.check(widgets.preferences.save(next), "change inherited style"); root.phase++;
                } else if (root.phase === 54) {
                    root.check(widgets.instanceRows.find(item => item.id === "a").style === "liquid", "inherited style follows defaults");
                    root.check(widgets.instanceRows.find(item => item.id === root.copyId).appearance.theme === "dark", "sibling explicit theme retained");
                    widgets.reloadSettings(); root.phase++;
                } else if (root.phase === 55) {
                    root.check(widgets.instanceRows.find(item => item.id === root.copyId).appearance.theme === "dark" && !widgets.canUndoDelete, "appearance persists through reload with history cleared");
                    root.appearanceBaseline = Layout.clone(widgets.instanceRows.find(item => item.id === "a").savedSettings);
                    root.appearanceDraft = Layout.clone(root.appearanceBaseline);
                    root.appearanceDraft.appearance.fontFamily = "Noto Sans"; root.appearanceDraft.appearance.theme = "light";
                    root.initialToken = widgets.preferences.token;
                    root.check(widgets.setWidgetAppearance(root.copyId, "fontFamily", "sans-serif"), "unrelated sibling edit while draft open"); root.phase++;
                } else if (root.phase === 56) {
                    root.check(!widgets.commitWidgetAppearance("a", root.appearanceDraft, root.appearanceBaseline, "player"), "reused ID with changed type rejected");
                    root.check(widgets.commitWidgetAppearance("a", root.appearanceDraft, root.appearanceBaseline, "clock"), "Apply merges with unrelated current changes"); root.phase++;
                } else if (root.phase === 57) {
                    var card = widgets.instanceRows.find(item => item.id === "a");
                    root.check(card.appearance.fontFamily === "Noto Sans" && card.appearance.theme === "light", "Apply saves fields atomically");
                    root.check(widgets.instanceRows.find(item => item.id === root.copyId).appearance.fontFamily === "sans-serif", "Apply preserves sibling edit");
                    root.check(!widgets.commitWidgetAppearance("a", root.appearanceDraft, root.appearanceBaseline, "clock"), "stale source snapshot rejected");
                    root.appearanceBaseline = Layout.clone(card.savedSettings); root.initialToken = widgets.preferences.token;
                    root.check(widgets.commitWidgetAppearance("a", root.appearanceBaseline, root.appearanceBaseline, "clock"), "repeated Apply accepted as noop"); root.phase++;
                } else if (root.phase === 58) {
                    root.check(widgets.preferences.token === root.initialToken, "no-op Apply makes no write");
                    console.log("MACSHELL_WIDGET_OUTPUTS_PASS"); Qt.quit();
                }
            } catch (error) { console.error("phase " + root.phase + ": " + error); Qt.exit(1); }
        }
    }
    Timer { interval: 12000; running: true; onTriggered: { console.error("OUTPUTS_TIMEOUT phase " + root.phase); Qt.exit(1); } }
}

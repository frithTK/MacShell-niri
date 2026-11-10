// Desktop widgets (macOS Tahoe style) for macshell.
//
//   * one desktop layer per display; Arrange covers windows until Done/Escape
//   * click-through while you are not editing; edit mode shows free grid slots and snaps widget moves / sizes without overlap
//   * Weather data from Open-Meteo, a local-date Calendar, a live local-time Clock, a Music player (MPRIS), shared Activity, and Batteries
//   * settings + placed widgets are saved to ~/.config/macwidgets/settings.json
//
//   qs -c macbar ipc call widgets refresh        re-fetch the weather now
//   qs -c macbar ipc call widgets edit true      start / stop editing
//
// niri: nothing is required. (No blur layerrule is needed, the Liquid Glass style blurs the wallpaper itself.)

import QtQuick
import "Locale" as Language
import QtQuick.Window
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Mpris
import "WidgetCatalog.js" as Catalog
import "WidgetLayout.js" as Layout
import "WidgetAppearance.js" as Appearance
import "WidgetVisibility.js" as Visibility
import "ActivityWidgetData.js" as ActivityData
import "BatteriesData.js" as BatteriesData
import "TimerWidgetData.js" as TimerData
import "ImageWidgetData.js" as ImageData

Scope {
    id: root

    property var hub: null
    readonly property var dock: hub ? hub.dock : null
    readonly property var stats: hub && hub.bar ? hub.bar.stats : null
    readonly property var activityAppearance: hub && hub.bar && hub.bar.activityPreferences ? hub.bar.activityPreferences.values : ({})
    function openActivity(output) { if (hub && hub.bar) hub.bar.showMonitoring(output); }

    // ───────────── state ─────────────
    property bool editing: false
    property string selectedId: ""
    property string selectionGeometry: ""
    property string editError: ""
    property double returnFocusId: 0
    property double returnWorkspaceId: -1
    property string editingOutput: ""
    property bool restoreAfterEdit: true
    property var desktopWindows: ({})
    readonly property var desktopWindow: desktopWindows[screenName] || null
    property string editingGeometry: ""
    property bool editingHadFocus: false
    property var draggingWidgets: ({})
    readonly property bool dragging: Object.keys(draggingWidgets).length > 0
    function setDragging(id, value) {
        var next = Object.assign({}, draggingWidgets);
        if (value) next[id] = true; else delete next[id];
        draggingWidgets = next;
    }
    function registerWindow(name, window) {
        var next = Object.assign({}, desktopWindows);
        if (window) next[name] = window; else delete next[name];
        desktopWindows = next;
    }
    function screenToken(name) {
        var plan = displayPlans.find(item => item.name === name);
        return plan && !plan.ambiguous ? JSON.stringify([plan.screen.width, plan.screen.height, plan.area]) : "";
    }
    property var focusController: Niri
    QtObject {
        id: editSession
        readonly property var surface: root.desktopWindows[root.editingOutput] || null
        readonly property var contentItem: surface ? surface.editor : null
        readonly property bool visible: root.editing && !!contentItem
        readonly property bool active: visible && !!surface.contentItem.Window.window && surface.contentItem.Window.window.active
        function activate() { Qt.callLater(() => { if (contentItem) contentItem.activate(); }); }
        function openActions() { Qt.callLater(() => { if (contentItem) contentItem.openActions(); }); }
        onActiveChanged: if (active) root.editingHadFocus = true
    }
    property alias editControls: editSession
    readonly property var selectedRow: renderedRows.find(item => item.wid === selectedId) || null
    function geometryToken(row) { return row ? JSON.stringify([row.woutput, row.wx, row.wy, row.wsize, row.wtype]) : ""; }
    function selectWidget(id) {
        if (!editing || !editable) return;
        selectedId = id;
        if (selectedRow) { editingOutput = selectedRow.woutput; editingGeometry = screenToken(editingOutput); }
        selectionGeometry = geometryToken(selectedRow); editError = "";
        editSession.activate();
    }
    function finishEditing(restore) { restoreAfterEdit = restore; editing = false; }
    onEditingChanged: {
        setEditorOpen("desktop", editing);
        if (editing) {
            if (!editable || !widgetsEnabled) { editing = false; return; }
            returnFocusId = focusController.activeToplevel ? focusController.activeToplevel.id : 0;
            returnWorkspaceId = focusController.focusedWorkspace ? focusController.focusedWorkspace.id : -1;
            editingOutput = screenName; editingGeometry = screenToken(editingOutput);
            selectedId = ""; editError = ""; editingHadFocus = false; editSession.activate();
        } else {
            var wasActive = editingHadFocus, restore = restoreAfterEdit, targetId = returnFocusId;
            selectedId = ""; editError = ""; restoreAfterEdit = true; draggingWidgets = ({}); editingHadFocus = false;
            if (wasActive && restore && targetId) Qt.callLater(() => {
                var target = root.focusController.windowMap[String(targetId)], active = root.focusController.activeToplevel;
                if (target && root.focusController.focusedWorkspace && root.focusController.focusedWorkspace.id === root.returnWorkspaceId
                    && target.data && target.data.workspace_id === root.returnWorkspaceId
                    && (!active || active.id === targetId || active.title === "macshell Widget Controls")) target.activate();
            });
        }
    }
    property alias preferences: widgetPreferences
    readonly property bool ready: widgetPreferences.ready
    readonly property bool editable: widgetPreferences.editable && displayChoices.length > 0
    readonly property bool settingsEditable: widgetPreferences.editable
    readonly property bool readOnly: widgetPreferences.readOnly
    readonly property bool pending: widgetPreferences.pending || widgetPreferences.loading
    readonly property bool canRecover: widgetPreferences.canRecover
    readonly property string error: widgetPreferences.error
    readonly property string notice: widgetPreferences.notice
    readonly property bool widgetsEnabled: widgetPreferences.values.enabled !== false
    onWidgetsEnabledChanged: if (!widgetsEnabled && editing) finishEditing(false)
    function setWidgetsEnabled(value) {
        if (!settingsEditable || typeof value !== "boolean") return false;
        var next = Layout.clone(widgetPreferences.values); next.enabled = value;
        return widgetPreferences.save(next);
    }
    property var visibilityClients: Niri.clients
    property bool visibilityConnected: Niri.connected
    property bool overviewOpen: Niri.overview
    function outputActive(name) { return widgetsEnabled && !Visibility.covered(name, visibilityClients, visibilityConnected, overviewOpen, editing); }
    property alias subscriptions: widgetSubscriptions
    property alias batteryDevices: batteriesModel
    BatteriesModel {
        id: batteriesModel
        battery: root.hub && root.hub.bar ? root.hub.bar.battery : null
        bluetooth: root.hub && root.hub.bar ? root.hub.bar.bluetooth : null
        active: root.ready && (widgetSubscriptions.counts.batteries > 0
            || Object.keys(root.editorSessions).length > 0 && root.instanceRows.some(row => row.type === "batteries" && row.supported))
    }
    property alias clockSource: widgetClock
    WidgetSubscriptions { id: widgetSubscriptions; instances: root.renderedRows; enabled: root.widgetsEnabled }
    WidgetClock { id: widgetClock; precision: widgetSubscriptions.clockPrecision }
    readonly property bool notesWanted: ready && widgetSubscriptions.counts.notes > 0
    Binding {
        target: root.hub && root.hub.notes ? root.hub.notes : null
        property: "backgroundEnabled"
        value: root.notesWanted
    }
    readonly property bool weatherWanted: ready && widgetSubscriptions.counts.weather > 0
    readonly property int activePlayers: widgetSubscriptions.counts.player
    readonly property bool lyricsWanted: widgetSubscriptions.counts.lyrics > 0
    property var lyricsOpenById: ({})
    function widgetLyricsOpen(id) { return lyricsOpenById[id] === true; }
    function setWidgetLyrics(id, open) {
        var record = widgetPreferences.values.widgets.find(item => item.id === id && item.type === "player" && Layout.supported(item));
        if (!record) return;
        var next = Object.assign({}, lyricsOpenById);
        if (open) next[id] = true; else delete next[id];
        lyricsOpenById = next;
    }
    property var screens: Quickshell.screens
    property var outputs: Niri.monitors.values
    readonly property var desktopScreen: {
        var eligible = displayPlans.filter(plan => !plan.ambiguous);
        var selected = eligible.find(plan => plan.profileId && plan.profileId === widgetPreferences.values.desktopOutput)
            || eligible.find(plan => focusController.focusedWorkspace && plan.name === focusController.focusedWorkspace.output) || eligible[0];
        return selected ? selected.screen : null;
    }
    readonly property var displayPlans: {
        var reservations = {};
        screens.forEach(screen => { reservations[screen.name] = Layout.reservedFor(screen.name, hub ? hub.bar : null, dock); });
        return Layout.displays(widgetPreferences.values, screens, outputs, reservations);
    }
    readonly property var displayChoices: displayPlans.filter(plan => !plan.ambiguous).map(plan => ({name: plan.name, label: plan.name}));
    function planFor(name) { return displayPlans.find(item => item.name === name) || null; }
    function placementScreen(name) {
        var plan = planFor(name);
        return plan && !plan.ambiguous ? {name: name, width: plan.screen.width, height: plan.screen.height, area: plan.area} : null;
    }
    function rowsForOutput(name) { return renderedRows.filter(item => item.woutput === name); }
    readonly property string screenName: desktopScreen ? desktopScreen.name : ""
    readonly property var origin: {
        if (!screens.length) return {};
        var screen = screens[0], output = Layout.outputFor(screen, outputs);
        return {name: screen.name, width: screen.width, height: screen.height, make: output.make || "", model: output.model || "", serial: output.serial || ""};
    }
    property var unplacedWidgets: []
    property var renderedRows: []
    readonly property var instanceRows: Layout.instances(widgetPreferences.values, displayPlans, renderedRows, unplacedWidgets)
    property var editorSessions: ({})
    property var undoStack: []
    property var pendingHistory: null
    readonly property bool canUndoDelete: settingsEditable && undoStack.length > 0
    function setEditorOpen(name, open) {
        var next = Object.assign({}, editorSessions);
        if (open) next[name] = true; else delete next[name];
        editorSessions = next;
        if (!Object.keys(next).length) {
            undoStack = [];
            if (pendingHistory) pendingHistory.remember = false;
        }
    }
    function saveWithHistory(next, operation) {
        pendingHistory = operation;
        if (widgetPreferences.save(next)) return true;
        pendingHistory = null; return false;
    }
    function completeMutation(success) {
        var operation = pendingHistory; pendingHistory = null;
        if (success && operation && operation.remember && Object.keys(editorSessions).length) {
            if (operation.kind === "delete") undoStack = undoStack.concat([operation.entry]);
            else undoStack = undoStack.slice(0, -1);
        }
        editError = success ? "" : widgetPreferences.error;
        mutationFinished(success);
    }
    signal mutationFinished(bool success)
    onDisplayPlansChanged: {
        if (editing && screenToken(editingOutput) !== editingGeometry) finishEditing(false);
        Qt.callLater(rebuild);
    }
    WidgetPreferences {
        id: widgetPreferences
        origin: root.origin
        onChanged: root.rebuild()
        onReadyChanged: if (!ready && root.editing) root.finishEditing(false)
        onReadOnlyChanged: if (readOnly && root.editing) root.finishEditing(false)
        onFinished: success => root.completeMutation(success)
    }
    Component {
        id: editToolbarComponent
        WidgetEditToolbar {
            foreground: root.darkGlass ? "#f5f5f7" : "#1d1d1f"
            accent: root.dock ? root.dock.accent : "#0a84ff"; family: root.fontFamily
            selectedId: root.selectedId; selectedType: root.selectedRow ? root.selectedRow.wtype : ""
            selectedSize: root.selectedRow ? root.selectedRow.wsize : "small"
            busy: root.pending || !root.editable; error: root.editError
            displayChoices: root.displayChoices; selectedOutput: root.selectedRow ? root.selectedRow.woutput : ""
            canUndo: root.canUndoDelete
            canConfigure: !!root.dock && !!root.dock.settingsEnabled
            onFinished: root.finishEditing(true)
            onResizeRequested: size => { if (!root.setSize(root.selectedId, size)) root.editError = "No room for this size. Try a smaller widget or rearrange the desktop."; }
            onMoveRequested: name => { if (!root.moveWidgetToOutput(root.selectedId, name)) root.editError = "No room on this display. Try a smaller widget or rearrange it first."; }
            onRemoveRequested: root.removeWidget(root.selectedId)
            onDuplicateRequested: if (!root.duplicateWidget(root.selectedId)) root.editError = "No room for another card on this display.";
            onUndoRequested: if (!root.undoDelete()) root.editError = "Could not restore this card. Reload settings and try again.";
            onConfigureRequested: {
                var id = root.selectedId;
                root.finishEditing(false);
                if (root.dock) root.dock.openWidgetPrefs(id);
            }
        }
    }

    // saved settings
    readonly property string tempUnit: widgetPreferences.values.defaults.tempUnit          // "C" | "F"
    readonly property string locMode: widgetPreferences.values.defaults.locMode        // "auto" (IP) | "city"
    readonly property string cityName: widgetPreferences.values.defaults.cityName

    readonly property string fontFamily: dock ? dock.fontFamily : "Inter"
    readonly property string configDir: (Quickshell.env("MACSHELL_SETTINGS_HOME") || Quickshell.env("HOME") + "/.config") + "/macwidgets"

    // Liquid Glass look = the Appearance sliders (Translucency / Blur / Liquid strength) of the Dock + Menu Bar
    readonly property real glassOpacity: dock ? dock.glassOpacity : 0.42
    readonly property real glassBlur: (dock ? dock.glassBlur : 5) + 11     // the Appearance blur slider, plus 11 more for widgets
    readonly property real glassLiquid: dock ? dock.glassLiquid : 1.0
    readonly property real glassRim: dock ? dock.glassRim : 0.45
    readonly property real glassGrain: dock ? dock.glassGrain : 0.03
    readonly property bool darkGlass: dock ? dock.darkMode : true

    // placed widgets: roles wid, wtype, wstyle, wsize, wmode, appearance/settings JSON, wx, wy
    property alias model: wmodel
    WidgetModel { id: wmodel; rows: root.renderedRows }
    readonly property int widgetCount: wmodel.count
    property bool anyLiquid: false
    property int rev: 0                    // bumped on every change to the list, so Settings bindings can re-evaluate count()
    property var unavailableWidgets: []

    readonly property var styleNames: Catalog.styles
    readonly property var typeNames: Catalog.names()
    readonly property var sizeNames: ({ small: "Small", medium: "Medium", large: "Large" })
    function dims(size) { return Catalog.dimensions(size); }
    // Size of the Player's contents (art, text, buttons) relative to the original design. The card itself fills the
    // normal widget footprint, like every other widget. 1.0 = original size.
    property real playerScale: 0.8
    readonly property int gridCell: 179
    readonly property int gridGapX: 28
    readonly property int gridGapY: 23
    readonly property int gridLeft: 21
    readonly property int gridTop: 56
    readonly property int gridRight: 21
    readonly property int gridBottom: 24
    function screenSize() { return desktopScreen ? [desktopScreen.width, desktopScreen.height] : [0, 0]; }
    function gridInfo(width, height) { return Layout.grid(width, height); }
    function recount() {
        anyLiquid = renderedRows.some(item => item.wstyle === "liquid");
        rev++;
    }
    function count(type, style, size) {
        return renderedRows.filter(item => item.wtype === type && (style === undefined || item.wstyle === style) && (size === undefined || item.wsize === size)).length;
    }
    function rebuild() {
        if (!widgetPreferences.ready) return;
        var values = widgetPreferences.values, plan = Layout.layout(values, displayPlans);
        if (JSON.stringify(renderedRows) !== JSON.stringify(plan.placed)) renderedRows = plan.placed;
        if (selectedId && geometryToken(selectedRow) !== selectionGeometry) { selectedId = ""; editError = ""; }
        unplacedWidgets = plan.unplaced;
        unavailableWidgets = values.widgets.filter(item => !Layout.supported(item));
        var open = {};
        values.widgets.forEach(item => { if (Layout.supported(item) && item.type === "player" && lyricsOpenById[item.id]) open[item.id] = true; });
        if (JSON.stringify(open) !== JSON.stringify(lyricsOpenById)) lyricsOpenById = open;
        recount();
    }
    function gridSlots(name) {
        var screen = placementScreen(name), slots = [];
        if (!screen) return slots;
        var g = Layout.grid(screen.width, screen.height, screen.area), rows = rowsForOutput(name);
        for (var row = 0; row < g.rows; row++) for (var column = 0; column < g.cols; column++) {
            var p = Layout.cell(screen, "small", column, row, rows, "");
            if (p) slots.push(p);
        }
        return slots;
    }
    function addWidget(type, style, size, outputName) {
        var definition = Catalog.find(type), sz = size || "small";
        if (!editable || !definition || definition.styles.indexOf(style) < 0 || definition.sizes.indexOf(sz) < 0) return false;
        var name = outputName || screenName, screen = placementScreen(name);
        if (!screen) return false;
        var position = Layout.free(screen, sz, rowsForOutput(name), "");
        var bound = Layout.withOutput(widgetPreferences.values, screen, outputs, screens);
        if (!position || !bound) return false;
        var next = bound.values;
        var id;
        do { id = "w" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 9); } while (next.widgets.some(item => item.id === id));
        next.widgets.push({id: id, type: type, version: 1, output: bound.profileId, position: {column: position.column, row: position.row}, settings: {style: style, size: sz}});
        return widgetPreferences.save(next);
    }
    function removeWidget(id) {
        if (!settingsEditable) return false;
        var next = Layout.clone(widgetPreferences.values);
        var index = next.widgets.findIndex(item => item.id === id);
        if (index < 0) return false;
        var record = next.widgets.splice(index, 1)[0];
        return saveWithHistory(next, {kind: "delete", remember: true, entry: {record: record, index: index}});
    }
    function undoDelete() {
        if (!canUndoDelete) return false;
        var entry = undoStack[undoStack.length - 1], next = Layout.clone(widgetPreferences.values);
        if (next.widgets.some(item => item.id === entry.record.id)) return false;
        // Merge into the current document; never roll back unrelated changes.
        // A disconnected/full display retains the restored card as Not placed.
        next.widgets.splice(Math.min(entry.index, next.widgets.length), 0, Layout.clone(entry.record));
        return saveWithHistory(next, {kind: "restore", remember: true});
    }
    function duplicateWidget(id) {
        if (!editable) return false;
        var source = instanceRows.find(item => item.id === id);
        if (!source || !source.supported || !source.canPlace) return false;
        var position = Layout.free(placementScreen(source.outputName), source.size, rowsForOutput(source.outputName), "");
        if (!position) return false;
        var next = Layout.clone(widgetPreferences.values), copy = Layout.clone(next.widgets.find(item => item.id === id));
        do { copy.id = "w" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 9); } while (next.widgets.some(item => item.id === copy.id));
        copy.position.column = position.column; copy.position.row = position.row;
        next.widgets.splice(next.widgets.findIndex(item => item.id === id) + 1, 0, copy);
        return widgetPreferences.save(next);
    }
    function removeLast(type, style, size) {
        var rows = renderedRows.filter(item => item.wtype === type && item.wstyle === style && item.wsize === size);
        return rows.length > 0 ? removeWidget(rows[rows.length - 1].wid) : false;
    }
    function setAppearance(id, key, value) {
        if (!settingsEditable) return false;
        var next = Layout.clone(widgetPreferences.values), item = next.widgets.find(item => item.id === id);
        if (!item || !Layout.supported(item)) return false;
        var definition = Catalog.find(item.type);
        if (key === "style" ? definition.styles.indexOf(value) < 0
            : key !== "mode" || definition.settings.indexOf("mode") < 0 || ["auto", "light", "dark"].indexOf(value) < 0) return false;
        item.settings = item.settings || {}; item.settings[key] = value;
        return widgetPreferences.save(next);
    }
    function setStyle(id, style) { return setAppearance(id, "style", style); }
    function setMode(id, mode) { return setAppearance(id, "mode", mode); }
    function setWidgetAppearance(id, key, value) {
        if (!settingsEditable || !Appearance.valid(key, value)) return false;
        var next = Layout.clone(widgetPreferences.values), item = next.widgets.find(item => item.id === id);
        if (!item || !Layout.supported(item) || !Appearance.supports(item.type, Layout.settings(item, next.defaults).style, key)) return false;
        item.settings = item.settings || {};
        item.settings.appearance = item.settings.appearance || {};
        item.settings.appearance[key] = value;
        return widgetPreferences.save(next);
    }
    function commitWidgetAppearance(id, draft, baseline, expectedType) {
        if (!settingsEditable || !draft || typeof draft !== "object" || Array.isArray(draft)) return false;
        var next = Layout.clone(widgetPreferences.values), item = next.widgets.find(item => item.id === id);
        if (!item || !Layout.supported(item) || item.type !== expectedType || JSON.stringify(item.settings || {}) !== JSON.stringify(baseline)) return false;
        var local = draft.appearance || {};
        if (typeof local !== "object" || Array.isArray(local) || Appearance.fields.some(key => local[key] !== undefined && !Appearance.valid(key, local[key]))) return false;
        if (draft.style !== undefined && Catalog.find(item.type).styles.indexOf(draft.style) < 0) return false;
        if (draft.mode !== undefined && ["auto", "light", "dark"].indexOf(draft.mode) < 0) return false;
        if (item.type === "activity" && !ActivityData.validSettings(draft.activity === undefined ? {} : draft.activity)) return false;
        if (item.type === "batteries" && !BatteriesData.validSettings(draft.batteries === undefined ? {} : draft.batteries)) return false;
        if (item.type === "timer" && !TimerData.validSettings(draft.timer === undefined ? {} : draft.timer)) return false;
        if (item.type === "image" && !ImageData.validSettings(draft.image === undefined ? {} : draft.image)) return false;
        item.settings = item.settings || {};
        var fields = ["style", "mode", "appearance"];
        if (item.type === "activity" || item.type === "batteries" || item.type === "timer" || item.type === "image") fields.push(item.type);
        fields.forEach(key => {
            if (draft[key] === undefined) delete item.settings[key]; else item.settings[key] = Layout.clone(draft[key]);
        });
        return widgetPreferences.save(next);
    }
    function resetWidgetAppearance(id, key) {
        if (!settingsEditable || (key !== "all" && key !== "style" && Appearance.fields.indexOf(key) < 0)) return false;
        var next = Layout.clone(widgetPreferences.values), item = next.widgets.find(item => item.id === id);
        if (!item || !Layout.supported(item)) return false;
        var settings = item.settings || {}, local = settings.appearance || {};
        if (key === "all") Appearance.fields.forEach(field => { delete local[field]; });
        else delete local[key];
        if (key === "all" || key === "style") delete settings.style;
        if (key === "all" || key === "theme") {
            delete settings.mode;
            // Explicit auto supersedes an inherited legacy Calendar mode.
            if (item.type === "calendar") local.theme = "auto";
        }
        if (Object.keys(local).length) settings.appearance = local; else delete settings.appearance;
        item.settings = settings;
        return widgetPreferences.save(next);
    }
    function setSize(id, size) {
        if (!editable || !Catalog.sizes.some(item => item.key === size)) return false;
        var row = renderedRows.find(item => item.wid === id);
        var next = Layout.clone(widgetPreferences.values), item = next.widgets.find(item => item.id === id);
        if (!item || !Layout.supported(item) || Catalog.find(item.type).sizes.indexOf(size) < 0) return false;
        var plan = displayPlans.find(plan => plan.profileId === item.output && !plan.ambiguous);
        if (!plan) return false;
        var screen = placementScreen(plan.name), g = Layout.grid(screen.width, screen.height, screen.area);
        var position = Layout.free(screen, size, rowsForOutput(plan.name), id,
            row ? row.wx : g.left + item.position.column * g.pitchX, row ? row.wy : g.top + item.position.row * g.pitchY);
        if (!position) return false;
        item.settings = item.settings || {}; item.settings.size = size;
        item.position.column = position.column; item.position.row = position.row;
        return widgetPreferences.save(next);
    }
    function moveWidget(id, x, y) {
        if (!editable) return false;
        var row = renderedRows.find(item => item.wid === id);
        if (!row) return false;
        var position = Layout.free(placementScreen(row.woutput), row.wsize, rowsForOutput(row.woutput), id, x, y);
        if (!position) return false;
        var next = Layout.clone(widgetPreferences.values), item = next.widgets.find(item => item.id === id);
        item.position.column = position.column; item.position.row = position.row;
        return widgetPreferences.save(next);
    }
    function moveWidgetToOutput(id, name) {
        if (!editable) return false;
        var screen = placementScreen(name), item = widgetPreferences.values.widgets.find(record => record.id === id);
        if (!screen || !item || !Layout.supported(item)) return false;
        var position = Layout.free(screen, Layout.settings(item, widgetPreferences.values.defaults).size, rowsForOutput(name), id);
        var bound = Layout.withOutput(widgetPreferences.values, screen, outputs, screens);
        if (!position || !bound) return false;
        var next = bound.values, moved = next.widgets.find(record => record.id === id);
        moved.output = bound.profileId; moved.position.column = position.column; moved.position.row = position.row;
        return widgetPreferences.save(next);
    }
    function setWeather(key, value) {
        if (!widgetPreferences.editable || ["tempUnit", "locMode", "cityName"].indexOf(key) < 0) return false;
        var next = Layout.clone(widgetPreferences.values); next.defaults[key] = value;
        return widgetPreferences.save(next);
    }
    function resetWeatherDefaults() { widgetPreferences.resetWeather(); }
    function reloadSettings() { if (!pending) { undoStack = []; widgetPreferences.refresh(); } }
    function recoverSettings() { if (!pending) { undoStack = []; widgetPreferences.recover(); } }

    // ───────────── music player (MPRIS) ─────────────
    // the player that is playing, otherwise the first one (same rule as the Menu Bar's media widget)
    readonly property var player: {
        var ps = Mpris.players.values, best = null;
        for (var i = 0; i < ps.length; i++) {
            if (ps[i].isPlaying) return ps[i];
            if (!best) best = ps[i];
        }
        return best;
    }
    // MPRIS does not announce the playback position; ask for it once a second while something plays and a Player widget exists
    Timer {
        id: positionPoll; objectName: "widgetPositionPoll"
        interval: root.lyricsWanted ? 250 : 1000        // quicker while lyrics are open, so lines change on time
        repeat: true
        running: root.player !== null && root.player.isPlaying && root.activePlayers > 0
        onTriggered: { try { root.player.positionChanged(); } catch (err) { } }
    }
    // ───────────── lyrics (LRCLIB, fetched only while a Player widget has its lyrics open) ─────────────
    property var lyricsLines: []               // [{ t: seconds (-1 = not synced), text }]
    property bool lyricsSynced: false
    property string lyricsState: "idle"        // idle | loading | ok | none
    property string lyricsReqKey: ""
    property string lrcTitle: ""
    property string lrcArtist: ""
    property string lrcAlbum: ""
    property string lrcDur: ""
    readonly property string trackKey: player ? (player.trackTitle + "|" + player.trackArtist + "|" + player.trackAlbum + "|"
                                                  + Math.round(player.lengthSupported ? player.length : 0)) : ""
    property int lyricsEpoch: 0
    property bool lyricsQueued: false
    function cancelLyrics() { lyricsEpoch++; lyricsQueued = false; lyricsSoon.stop(); lrcProc.running = false; }
    onActivePlayersChanged: if (activePlayers > 0 && player && player.positionSupported) { try { player.positionChanged(); } catch (err) {} }
    onTrackKeyChanged: {
        cancelLyrics();
        lyricsLines = []; lyricsSynced = false; lyricsState = "idle";
        if (lyricsWanted) lyricsSoon.restart();
    }
    onLyricsWantedChanged: {
        if (!lyricsWanted) { cancelLyrics(); if (lyricsState === "loading") lyricsState = "idle"; }
        else if (lyricsState === "idle") lyricsSoon.restart();
    }
    Timer { id: lyricsSoon; interval: 500; onTriggered: root.fetchLyrics() }

    function fetchLyrics() {
        if (!lyricsWanted || !player || player.trackTitle === "") return;
        if (lrcProc.running) { lyricsQueued = true; return; }
        lyricsQueued = false; lyricsEpoch++;
        lyricsReqKey = trackKey;
        lrcTitle = player.trackTitle; lrcArtist = player.trackArtist; lrcAlbum = player.trackAlbum;
        lrcDur = String(Math.round(player.lengthSupported ? player.length : 0));
        lyricsState = "loading";
        lrcProc.running = true;
    }
    function parseLrc(txt) {
        var out = [], lines = String(txt).split(/\r?\n/);
        for (var i = 0; i < lines.length; i++) {
            var line = lines[i], re = /\[(\d+):(\d+(?:\.\d+)?)\]/g, times = [], m;
            while ((m = re.exec(line)) !== null) times.push(parseInt(m[1]) * 60 + parseFloat(m[2]));
            if (times.length === 0) continue;
            var text = line.replace(/\[[^\]]*\]/g, "").trim();
            for (var j = 0; j < times.length; j++) out.push({ t: times[j], text: text });
        }
        out.sort(function (a, b) { return a.t - b.t; });
        return out;
    }
    function applyLyrics(raw) {
        var o = null;
        try { o = JSON.parse(raw); } catch (err) { }
        if (Array.isArray(o)) {                           // search fallback: prefer a result with synced lyrics
            var pick = null;
            for (var i = 0; i < o.length; i++) {
                if (o[i].syncedLyrics) { pick = o[i]; break; }
                if (!pick && o[i].plainLyrics) pick = o[i];
            }
            o = pick;
        }
        if (!o || o.instrumental) { lyricsLines = []; lyricsSynced = false; lyricsState = "none"; return; }
        if (o.syncedLyrics) {
            var l = parseLrc(o.syncedLyrics);
            if (l.length > 0) { lyricsLines = l; lyricsSynced = true; lyricsState = "ok"; return; }
        }
        if (o.plainLyrics) {
            var ps = String(o.plainLyrics).split(/\r?\n/), pl = [];
            for (var k = 0; k < ps.length; k++) if (ps[k].trim() !== "") pl.push({ t: -1, text: ps[k].trim() });
            if (pl.length > 0) { lyricsLines = pl; lyricsSynced = false; lyricsState = "ok"; return; }
        }
        lyricsLines = []; lyricsSynced = false; lyricsState = "none";
    }
    readonly property string fetchHelper: decodeURIComponent(Qt.resolvedUrl("widget-fetch.sh").toString().replace(/^file:\/\//, ""))
    Process {
        id: lrcProc
        command: ["sh", root.fetchHelper, "lyrics", String(root.lyricsEpoch), root.lrcTitle, root.lrcArtist, root.lrcAlbum, root.lrcDur]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var message = JSON.parse(text);
                    if (!root.lyricsWanted || message.epoch !== root.lyricsEpoch || root.lyricsReqKey !== root.trackKey) return;
                    if (message.success) root.applyLyrics(JSON.stringify(message.result));
                    else root.lyricsState = "none";
                } catch (error) { /* Cancelled requests may end before writing a complete response. */ }
            }
        }
        onExited: (code, status) => {
            if (root.lyricsWanted && root.lyricsQueued) Qt.callLater(root.fetchLyrics);
            else if (code !== 0 && root.lyricsWanted) root.lyricsState = "none";
        }
    }

    // ───────────── weather data (Open-Meteo) ─────────────
    property bool wxReady: false
    property string wxCity: "—"
    property bool wxLocated: true
    property int wxTemp: 0
    property int wxHi: 0
    property int wxLo: 0
    property int wxCode: 0
    property bool wxDay: true
    property string wxError: ""
    property real wxLat: 0
    property real wxLon: 0
    property string wxPlace: ""
    property var wxHourly: []
    property var wxDaily: []

    function wmo(code, day) {
        switch (code) {
        case 0:  return day ? { t: "Sunny", k: "sun" } : { t: "Clear", k: "moon" };
        case 1:  return day ? { t: "Mostly Sunny", k: "sun" } : { t: "Mostly Clear", k: "moon" };
        case 2:  return { t: "Partly Cloudy", k: day ? "partly" : "partlyNight" };
        case 3:  return { t: "Cloudy", k: "cloud" };
        case 45: case 48: return { t: "Foggy", k: "fog" };
        case 51: case 53: case 55: return { t: "Drizzle", k: "rain" };
        case 56: case 57: return { t: "Freezing Drizzle", k: "rain" };
        case 61: return { t: "Light Rain", k: "rain" };
        case 63: return { t: "Rain", k: "rain" };
        case 65: return { t: "Heavy Rain", k: "rain" };
        case 66: case 67: return { t: "Freezing Rain", k: "rain" };
        case 71: return { t: "Light Snow", k: "snow" };
        case 73: return { t: "Snow", k: "snow" };
        case 75: case 77: return { t: "Heavy Snow", k: "snow" };
        case 80: case 81: return { t: "Showers", k: "rain" };
        case 82: return { t: "Heavy Showers", k: "rain" };
        case 85: case 86: return { t: "Snow Showers", k: "snow" };
        case 95: case 96: case 99: return { t: "Thunderstorms", k: "storm" };
        }
        return { t: "Cloudy", k: "cloud" };
    }
    readonly property var wxInfo: wmo(wxCode, wxDay)
    function hourLabel(iso, first) {
        if (first) return Language.I18n.text("ui.t_fe18013d93d2");
        var h = parseInt(iso.substr(11, 2));
        return (h % 12 === 0 ? 12 : h % 12) + (h < 12 ? "AM" : "PM");
    }
    function dayLabel(iso, i) {
        if (i === 0) return Language.I18n.text("ui.t_2b065c7c9ce4");
        var d = new Date(parseInt(iso.substr(0, 4)), parseInt(iso.substr(5, 2)) - 1, parseInt(iso.substr(8, 2)));
        return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][d.getDay()];
    }

    property int weatherEpoch: 0
    property bool weatherQueued: false
    property double weatherUpdatedAt: 0
    readonly property string weatherKey: JSON.stringify([tempUnit, locMode, cityName])
    function stopWeather() {
        weatherEpoch++; weatherQueued = false; refreshDebounce.stop(); weatherSchedule.stop(); weatherProc.running = false;
    }
    function scheduleWeather(delay) {
        if (!weatherWanted) return;
        weatherSchedule.interval = Math.max(1000, delay); weatherSchedule.restart();
    }
    function resumeWeather() {
        var age = Date.now() - weatherUpdatedAt;
        if (!wxReady || age < 0 || age >= 15 * 60 * 1000) refreshSoon();
        else scheduleWeather(15 * 60 * 1000 - age);
    }
    onWeatherKeyChanged: {
        stopWeather(); wxReady = false; wxError = ""; weatherUpdatedAt = 0;
        if (weatherWanted) refreshSoon();
    }
    onWeatherWantedChanged: if (weatherWanted) resumeWeather(); else stopWeather()
    function refresh() {
        if (!weatherWanted) return;
        refreshDebounce.stop();
        if (weatherProc.running) { weatherQueued = true; return; }
        weatherQueued = false; weatherEpoch++; weatherSchedule.stop(); weatherProc.running = true;
    }
    function refreshSoon() { if (weatherWanted) refreshDebounce.restart(); }
    Timer { id: refreshDebounce; interval: 700; onTriggered: root.refresh() }
    Timer { id: weatherSchedule; onTriggered: root.refresh() }
    function acceptWeather(text) {
        var message;
        try { message = JSON.parse(text); } catch (error) { return; }
        if (!weatherWanted || message.epoch !== weatherEpoch) return;
        if (!message.success) { wxError = message.error || Language.I18n.text("ui.t_401718624faf"); scheduleWeather(60000); return; }
        try {
            var result = message.result, o = result.forecast;
            wxLat = result.latitude; wxLon = result.longitude; wxPlace = result.place; wxLocated = result.located;
            root.wxTemp = Math.round(o.current.temperature_2m);
            root.wxCode = o.current.weather_code;
            root.wxDay = o.current.is_day === 1;
            root.wxHi = Math.round(o.daily.temperature_2m_max[0]);
            root.wxLo = Math.round(o.daily.temperature_2m_min[0]);
            // next hours (starting with the current one) and the coming days
            var hrs = [], ht = o.hourly.time, cur = String(o.current.time).substring(0, 13), start = 0, i;
            for (i = 0; i < ht.length; i++) if (ht[i].substring(0, 13) === cur) { start = i; break; }
            for (i = start; i < ht.length && hrs.length < 6; i++)
                hrs.push({ h: root.hourLabel(ht[i], hrs.length === 0), t: Math.round(o.hourly.temperature_2m[i]),
                           k: root.wmo(o.hourly.weather_code[i], o.hourly.is_day[i] === 1).k });
            var dys = [], dt = o.daily.time;
            for (i = 0; i < dt.length && i < 5; i++)
                dys.push({ d: root.dayLabel(dt[i], i), lo: Math.round(o.daily.temperature_2m_min[i]),
                           hi: Math.round(o.daily.temperature_2m_max[i]), k: root.wmo(o.daily.weather_code[i], true).k });
            root.wxHourly = hrs; root.wxDaily = dys;
            root.wxCity = root.wxPlace;
            root.wxReady = true;
            root.wxError = "";
            weatherUpdatedAt = Date.now(); scheduleWeather(15 * 60 * 1000);
        } catch (error) { wxError = "Weather unavailable."; scheduleWeather(60000); }
    }
    Process {
        id: weatherProc
        command: ["sh", root.fetchHelper, "weather", String(root.weatherEpoch), root.locMode, root.cityName, root.tempUnit]
        stdout: StdioCollector { onStreamFinished: root.acceptWeather(text) }
        onExited: (code, status) => {
            if (root.weatherWanted && root.weatherQueued) Qt.callLater(root.refresh);
            else if (code !== 0 && root.weatherWanted) { root.wxError = "Weather unavailable."; root.scheduleWeather(60000); }
        }
    }

    // ───────────── Liquid Glass backend ─────────────
    // Same shader as the Dock / Menu Bar (liquidglass.frag), compiled with qsb into ~/.config/macwidgets/.
    property string glassState: "idle"                     // idle → building → ready | failed
    readonly property string glassShaderSrc: decodeURIComponent(Qt.resolvedUrl("liquidglass.frag").toString().replace("file://", ""))
    readonly property string glassShaderOut: configDir + "/liquidglass.frag.qsb"
    readonly property bool activeLiquid: widgetSubscriptions.activeViews.some(view => renderedRows.some(row => row.wid === view.instanceId && row.wstyle === "liquid"))
    onActiveLiquidChanged: if (activeLiquid) startGlass()
    onReadyChanged: if (ready && activeLiquid) startGlass()
    function startGlass() {
        if (!ready || !activeLiquid || glassState === "ready" || glassState === "building" || glassState === "failed") return;
        glassState = "building";
        qsbProc.running = true;
        if (hub) hub.refreshWallpaper();
    }
    Process {
        id: qsbProc
        command: ["sh", "-c",
            "mkdir -p \"$(dirname \"$2\")\"; "
            + "for q in qsb qsb6 qsb-qt6 /usr/lib/qt6/bin/qsb /usr/lib64/qt6/bin/qsb /usr/lib/qt/bin/qsb; do "
            + "  if command -v \"$q\" >/dev/null 2>&1; then \"$q\" --qt6 -o \"$2\" \"$1\" && exit 0; fi; "
            + "done; "
            + "[ -f \"$1.qsb\" ] && cp \"$1.qsb\" \"$2\" && exit 0; "
            + "exit 1",
            "sh", root.glassShaderSrc, root.glassShaderOut]
        stderr: StdioCollector { onStreamFinished: if (text.trim() !== "") console.log("[macwidgets-glass] qsb:", text.trim()) }
        onExited: (code, status) => root.glassState = (code === 0 ? "ready" : "failed")
    }
    Binding { target: root.hub; property: "widgetsWantWallpaper"; value: root.activeLiquid }

    // wallpaper behind the widgets (same lookup as the Dock's Liquid Glass)
    readonly property var wallpaperMap: hub ? hub.wallpaperMap : ({})
    function wallpaperFor(screenName) {
        var p = (dock && dock.wallpaperPath !== "") ? dock.wallpaperPath
              : (wallpaperMap["wallpaper.monitors." + screenName] || wallpaperMap["wallpaper.last"]
                 || wallpaperMap["wallpaper.default"] || "");
        if (p.indexOf("~/") === 0) p = Quickshell.env("HOME") + p.substring(1);
        return p;
    }
    function fileUrl(p) {
        if (p === "") return "";
        if (p.indexOf("file://") === 0) return p;
        return "file://" + encodeURI(p).replace(/#/g, "%23").replace(/\?/g, "%3F");
    }

    // ───────────── the desktop layer ─────────────
    Variants {
        model: root.ready && root.widgetsEnabled ? root.screens.filter(screen => root.editing || root.rowsForOutput(screen.name).length > 0) : []

        PanelWindow {
            id: win
            required property var modelData
            property string registeredOutput: ""
            readonly property var editor: toolbar.item
            screen: modelData
            anchors { left: true; right: true; top: true; bottom: true }
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore

            WlrLayershell.namespace: "macwidgets"
            WlrLayershell.layer: root.editing ? WlrLayer.Overlay : WlrLayer.Bottom
            WlrLayershell.keyboardFocus: root.editing && win.modelData.name === root.editingOutput ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
            Component.onCompleted: { registeredOutput = modelData.name; root.registerWindow(registeredOutput, win); }
            Component.onDestruction: if (root.desktopWindows[registeredOutput] === win) root.registerWindow(registeredOutput, null)
            mask: WidgetInputMask { registry: inputRegistry }

            FocusScope {
                id: ui
                objectName: "widgetArrangeScene"
                anchors.fill: parent
                focus: root.editing
                Keys.onEscapePressed: root.finishEditing(true)

                WidgetInputRegistry {
                    id: inputRegistry; objectName: "widgetInputs"; outputName: win.modelData.name; surfaceItem: ui
                    editing: root.editing; enabled: win.visible
                    blocked: !root.ready || (root.pending && !root.editing)
                }
                MouseArea { anchors.fill: parent; enabled: root.editing; acceptedButtons: Qt.LeftButton | Qt.RightButton; onClicked: root.selectWidget("") }

                Rectangle {
                    objectName: "widgetArrangeBackdrop"
                    anchors.fill: parent
                    visible: root.editing
                    color: root.darkGlass ? "#16171b" : "#e5e5ed"
                    Image {
                        anchors.fill: parent; fillMode: Image.PreserveAspectCrop; asynchronous: true
                        source: root.editing ? root.fileUrl(root.wallpaperFor(win.modelData.name)) : ""
                    }
                    Rectangle { anchors.fill: parent; color: "black"; opacity: .16 }
                }

                Repeater {   // free Small-sized grid cells; Medium and Large snap across 2-cell footprints
                    model: {
                        var revision = root.rev;
                        return root.editing ? root.gridSlots(win.modelData.name) : [];
                    }
                    delegate: Rectangle {
                        required property var modelData
                        x: modelData.x
                        y: modelData.y
                        width: root.gridCell
                        height: root.gridCell
                        radius: 28
                        color: Qt.rgba(1, 1, 1, 0.018)
                        border.width: 1
                        border.color: Qt.rgba(1, 1, 1, 0.10)
                    }
                }

                WidgetModel { id: outputWidgets; rows: root.rowsForOutput(win.modelData.name) }
                Repeater {
                    model: outputWidgets
                    delegate: Item {
                        id: ww
                        objectName: "desktopWidget_" + wid
                        required property string wid
                        required property string wtype
                        required property string wstyle
                        required property string wsize
                        required property string wmode
                        required property string wappearance
                        required property string wactivity
                        required property string wbatteries
                        required property string wtimer
                        required property string wimage
                        required property real wx
                        required property real wy

                        x: wx + dragArea.offsetX
                        y: wy + dragArea.offsetY
                        readonly property var baseDims: root.dims(wsize)
                        readonly property real radiusPx: 28 * (wsize === "small" ? 168 / 158 : (wsize === "medium" ? 358 / 338 : 1))
                        width: baseDims[0]
                        height: baseDims[1]
                        WidgetInputTarget {
                            id: inputTarget; registry: inputRegistry
                            instanceId: ww.wid; outputName: win.modelData.name
                            sourceItem: ww; targetItem: ui; interactive: visual.interactive
                            nativeRegion: Region {
                                x: Math.floor(inputTarget.rect.x); y: Math.floor(inputTarget.rect.y)
                                width: inputTarget.active ? Math.ceil(inputTarget.rect.x + inputTarget.rect.width) - x : 0
                                height: inputTarget.active ? Math.ceil(inputTarget.rect.y + inputTarget.rect.height) - y : 0
                            }
                        }

                        WidgetVisual {
                            id: visual
                            objectName: "widgetVisual_" + ww.wid
                            anchors.fill: parent
                            host: root; instanceId: ww.wid
                            renderActive: root.outputActive(win.modelData.name) && ww.visible && ww.opacity > .001
                            wtype: ww.wtype; wstyle: ww.wstyle; wsize: ww.wsize; wmode: ww.wmode
                            wappearance: ww.wappearance
                            wactivity: ww.wactivity
                            wbatteries: ww.wbatteries
                            wtimer: ww.wtimer
                            wimage: ww.wimage
                            sx: ww.x; sy: ww.y
                            sname: win.modelData.name; sw: win.modelData.width; sh: win.modelData.height
                        }

                        scale: dragArea.pressed ? 1.03 : 1.0
                        Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                        z: dragArea.pressed ? 10 : 1

                        // edit mode: outline + drag + remove
                        Rectangle {
                            anchors.fill: parent
                            visible: root.editing
                            radius: ww.radiusPx
                            color: "transparent"
                            border.width: 2
                            border.color: root.selectedId === ww.wid ? (root.dock ? root.dock.accent : "#0a84ff") : Qt.rgba(1, 1, 1, 0.55)
                        }
                        WidgetEditHandle {
                            id: dragArea
                            anchors.fill: parent
                            enabled: root.editing && root.editable
                            targetItem: ww; coordinateItem: ui
                            onPressedChanged: root.setDragging(ww.wid, pressed)
                            Component.onDestruction: root.setDragging(ww.wid, false)
                            onMoveRequested: (x, y) => root.moveWidget(ww.wid, x, y)
                            onSelectRequested: root.selectWidget(ww.wid)
                            onContextRequested: { root.selectWidget(ww.wid); editSession.openActions(); }
                        }
                        Rectangle {   // "−" remove badge
                            visible: root.editing
                            x: -8; y: -8
                            width: 24; height: 24; radius: 12
                            color: minusMa.pressed ? "#D8D8DC" : "#F2F2F5"
                            border.width: 1
                            border.color: Qt.rgba(0, 0, 0, 0.18)
                            Rectangle { anchors.centerIn: parent; width: 10; height: 2; radius: 1; color: "#3A3A3C" }
                            MouseArea { id: minusMa; anchors.fill: parent; enabled: root.editable; onClicked: root.removeWidget(ww.wid) }
                        }
                    }
                }
                Loader {
                    id: toolbar; objectName: "widgetArrangeToolbar"
                    anchors.top: parent.top; anchors.topMargin: 8; anchors.horizontalCenter: parent.horizontalCenter
                    width: Math.max(0, Math.min(760, parent.width - 24)); height: 40; z: 100
                    active: root.editing && win.modelData.name === root.editingOutput
                    visible: active && !root.dragging
                    sourceComponent: editToolbarComponent
                    onLoaded: item.activate()
                }
            }
        }
    }

    function resourceState() {
        return {enabled: widgetsEnabled, views: widgetSubscriptions.views.length,
                activeViews: widgetSubscriptions.activeViews.length, consumers: widgetSubscriptions.consumers, sources: widgetSubscriptions.counts,
                acquired: widgetSubscriptions.acquired, released: widgetSubscriptions.released,
                clock: {precision: widgetClock.precision, running: widgetClock.running, interval: widgetClock.interval},
                positionPolling: positionPoll.running, positionInterval: positionPoll.interval, weatherScheduled: weatherSchedule.running, lyricsWanted: lyricsWanted,
                weatherPid: weatherProc.processId || 0, lyricsPid: lrcProc.processId || 0};
    }

    IpcHandler {
        target: "widgets"
        function layout(): string {
            return JSON.stringify({ready: root.ready, pending: root.pending, editing: root.editing,
                outputs: root.displayPlans.map(plan => ({name: plan.name, profile: plan.profileId, ambiguous: plan.ambiguous,
                    width: plan.screen.width, height: plan.screen.height, area: plan.area})),
                placed: root.renderedRows, unplaced: root.unplacedWidgets, unavailable: root.unavailableWidgets.length});
        }
        function resources(): string { return JSON.stringify(root.resourceState()); }
        function refresh(): void { root.refresh(); }
        function edit(on: bool): void { root.editing = on && root.editable; }
    }
}

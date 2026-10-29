import QtQuick
import QtQuick.Window
import QtTest
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "." as Port
import "WidgetLayout.js" as Layout

ShellRoot {
    id: root
    property int behindClicks: 0
    property int focusRestores: 0
    property int activityOpens: 0
    property string activityOutput: ""
    property bool behindPainted: false
    property bool frontPainted: false
    property string outputName: Quickshell.env("MACSHELL_INPUT_PROBE_OUTPUT")
    readonly property var output: Quickshell.screens.find(screen => screen.name === outputName) || null
    QtObject {
        id: fakeBar; property bool settingsReady: true; property bool barEnabled: true; property int barHeight: 0
        function showMonitoring(output) { root.activityOpens++; root.activityOutput = output; }
    }
    QtObject {
        id: fakeHub
        property var dock: null
        property var bar: fakeBar
        property bool widgetsWantWallpaper: false
        property var wallpaperMap: ({})
        function refreshWallpaper() {}
    }
    QtObject {
        id: priorNode
        property int id: 1
        property var data: ({workspace_id: 1})
        property string title: "macshell Widget Input Probe"
        function activate() { root.focusRestores++; prior.requestActivate(); }
    }
    QtObject { id: editorNode; property int id: 2; property string title: "macshell Widget Controls" }
    QtObject {
        id: fakeFocus
        readonly property var activeToplevel: widgets.editControls.active ? editorNode : prior.active ? priorNode : null
        property var focusedWorkspace: ({id: 1})
        property var windowMap: ({"1": priorNode, "2": editorNode})
    }
    Window {
        id: prior
        title: "macshell Widget Input Probe"; width: 300; height: 120
        minimumWidth: 300; maximumWidth: 300; minimumHeight: 120; maximumHeight: 120
        flags: Qt.Dialog; transientParent: null; visible: true; color: "#30343c"
        Text { anchors.centerIn: parent; text: "Isolated widget input check"; color: "white" }
    }
    PanelWindow {
        id: behind
        screen: root.output; anchors {left: true; top: true}
        margins {left: 80; top: 80}
        implicitWidth: 800; implicitHeight: 700
        exclusionMode: ExclusionMode.Ignore; color: "#252a33"
        WlrLayershell.namespace: "macshell-widget-input-back"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        Text { x: 12; y: 12; text: "Widget input probe · fake media and isolated settings"; color: "#c4c8d0" }
        MouseArea { anchors.fill: parent; acceptedButtons: Qt.LeftButton | Qt.RightButton; onClicked: root.behindClicks++ }
        Connections { target: behind.contentItem.Window.window; function onFrameSwapped() { root.behindPainted = true; } }
    }
    Port.MacWidgets {
        id: widgets; hub: fakeHub; focusController: fakeFocus
        screens: root.output && root.behindPainted ? [root.output] : []
        outputs: root.output ? [{name: root.outputName, make: "Demo", model: "Probe", serial: "probe"}] : []
    }
    Connections {
        target: widgets.desktopWindow ? widgets.desktopWindow.contentItem.Window.window : null
        function onFrameSwapped() { root.frontPainted = true; }
    }
    Item {
        parent: widgets.desktopWindow ? widgets.desktopWindow.contentItem : null
        TestEvent { id: events }
    }
    function find(item, name) {
        if (!item) return null;
        if (item.objectName === name) return item;
        for (var child of item.children || []) { var result = find(child, name); if (result) return result; }
        return null;
    }
    function card(id) { return widgets.desktopWindow ? find(widgets.desktopWindow.contentItem, "desktopWidget_" + id) : null; }
    function state() {
        var surface = widgets.desktopWindow ? widgets.desktopWindow.contentItem : null;
        var registry = find(surface, "widgetInputs"), points = {};
        for (var row of widgets.renderedRows) {
            var item = card(row.wid), button = find(item, "playerButton_play") || find(item, "activityOpen");
            if (button) { var p = button.mapToItem(surface, button.width / 2, button.height / 2); points[row.wid] = {x: p.x, y: p.y}; }
        }
        return {ready: widgets.ready && root.behindPainted && root.frontPainted, pending: widgets.pending,
                width: root.output ? root.output.width : 0, height: root.output ? root.output.height : 0,
                behind: root.behindClicks, plays: widgets.testPlayCount, targets: registry ? registry.activeTargets.length : -1,
                editing: widgets.editing, selected: widgets.selectedId, editorActive: widgets.editControls.active,
                editorVisible: widgets.editControls.visible, priorActive: prior.active, restores: root.focusRestores,
                points: points, rows: widgets.renderedRows, saved: widgets.preferences.values.widgets, token: widgets.preferences.token,
                resources: widgets.resourceState(), error: widgets.error || widgets.notice};
    }
    IpcHandler {
        target: "probe"
        function state(): string { return JSON.stringify(root.state()); }
        function activity(): string { return JSON.stringify({opens: root.activityOpens, output: root.activityOutput}); }
        function addActivity(): void { widgets.addWidget("activity", "normal", "small", root.outputName); }
        function addBatteries(): void { widgets.addWidget("batteries", "normal", "small", root.outputName); }
        function focus(): void { prior.requestActivate(); }
        function reserve(top: int): void { fakeBar.barHeight = top; }
        function media(on: bool): void { widgets.testPlayerAvailable = on; }
        function displayWidgets(on: bool): void { widgets.setWidgetsEnabled(on); }
        function cover(on: bool, known: bool): void {
            widgets.visibilityConnected = true;
            widgets.overviewOpen = false;
            widgets.visibilityClients = on ? [{output: root.outputName, geometryKnown: known,
                fullscreen: 1, workspaceActive: true, mapped: true, hidden: false}] : [];
        }
        function setCardVisible(id: string, on: bool): void { var item = root.card(id); if (item) item.visible = on; }
        function scale(id: string, factor: real): void { var item = root.card(id); if (item) item.scale = factor; }
        function editing(on: bool): void { widgets.editing = on; }
        function move(id: string, column: int, row: int): void {
            var g = widgets.gridInfo(root.output.width, root.output.height);
            widgets.moveWidget(id, g.left + column * g.pitchX, g.top + row * g.pitchY);
        }
        function remove(id: string): void { widgets.removeWidget(id); }
        function action(name: string): void {
            var bar = widgets.editControls.contentItem;
            if (bar) bar.openActions();
            var button = root.find(bar, name) || (bar ? bar.actionButton(name) : null);
            if (widgets.editControls.active && button && button.enabled) events.mouseClick(button, button.width / 2, button.height / 2, Qt.LeftButton, Qt.NoModifier, 0);
        }
        function clearPlayers(): void {
            var next = Layout.clone(widgets.preferences.values); next.widgets = next.widgets.filter(item => item.type !== "player"); widgets.preferences.save(next);
        }
        function sendEscape(): void { if (widgets.editControls.active) events.keyClick(Qt.Key_Escape, Qt.NoModifier, 0); }
        function done(): void {
            var button = root.find(widgets.editControls.contentItem, "widgetEditDone");
            if (widgets.editControls.active && button) events.mouseClick(button, button.width / 2, button.height / 2, Qt.LeftButton, Qt.NoModifier, 0);
        }
        function quit(): void { Qt.quit(); }
    }
    Timer { interval: 60000; running: true; onTriggered: { console.error("WIDGET_INPUT_PROBE_TIMEOUT"); Qt.exit(1); } }
}

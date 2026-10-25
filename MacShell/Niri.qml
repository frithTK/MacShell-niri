pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Scope {
    id: root
    property bool connected: false
    property var clients: []
    property var monitorData: []
    property var keyboard: ({ names: [], current_idx: 0 })
    property var windowMap: ({})
    property var activeToplevel: null
    property var focusedWorkspace: null
    property var focusedMonitor: null
    property bool overview: false
    property double hiddenWorkspaceId: -1
    readonly property QtObject toplevels: QtObject { property var values: [] }
    readonly property QtObject monitors: QtObject { property var values: root.monitorData }
    readonly property QtObject workspaces: QtObject { property var values: [] }
    signal updated()
    property string stateKey: ""
    property string windowsKey: ""
    property string monitorsKey: ""
    property string keyboardKey: ""
    property string workspacesKey: ""
    readonly property string helper: Qt.resolvedUrl("niri_ipc.py").toString().replace(/^file:\/\//, "")
    Component { id: windowComponent; NiriWindow {} }
    function action(args) { Quickshell.execDetached(["niri", "msg", "action"].concat(args.map(String))); }
    function request(value) { if (connected) bridge.write(JSON.stringify(value) + "\n"); }
    function focusWorkspace(id) { request({ Action: { FocusWorkspace: { reference: { Id: Number(id) } } } }); }
    function hideActive() {
        if (!activeToplevel || !focusedWorkspace) return;
        var choices = workspaces.values.filter(function(w) { return w.output === root.focusedWorkspace.output; });
        choices.sort(function(a, b) { return a.idx - b.idx; });
        var target = choices.find(function(w) { return w.id === root.hiddenWorkspaceId; }) || choices[choices.length - 1];
        if (!target || target.id === focusedWorkspace.id) return;
        hiddenWorkspaceId = target.id;
        request({ Action: { MoveWindowToWorkspace: { window_id: activeToplevel.id, reference: { Id: target.id }, focus: false } } });
    }
    function showHidden() { if (hiddenWorkspaceId > 0) focusWorkspace(hiddenWorkspaceId); }
    function monitorFor(screen) {
        for (var i = 0; i < monitorData.length; i++) if (monitorData[i].name === screen.name) return monitorData[i];
        return null;
    }
    function workspaceLabel(id) {
        var ws = workspaces.values;
        for (var i = 0; i < ws.length; i++) if (ws[i].id === id) return ws[i].name;
        return String(id);
    }
    function accept(message) {
        connected = message.connected;
        if (!connected) { stateKey = ""; if (message.error) console.warn("[niri] " + message.error); return; }
        if (message.titles) {
            for (var identifier in message.titles) {
                var target = windowMap[identifier];
                if (!target) continue;
                target.updateTitle(message.titles[identifier]);
                var client = clients.find(w => String(w.id) === identifier);
                if (client) client.title = message.titles[identifier];
            }
            return;
        }
        var state = message.state, nextKey = JSON.stringify(state);
        if (stateKey === nextKey) return;
        stateKey = nextKey;
        var nextWindows = JSON.stringify(state.windows), nextMonitors = JSON.stringify(state.monitors), nextKeyboard = JSON.stringify(state.keyboard);
        var nextWorkspaces = JSON.stringify(state.workspaces) + JSON.stringify(state.windows.map(w => [w.id, w.workspace_id]));
        var list = toplevels.values, retired = [], i;
        if (windowsKey !== nextWindows) {
            var live = {}, ordered = [], active = null, membershipChanged = false;
            for (i = 0; i < state.windows.length; i++) {
                var data = state.windows[i], key = String(data.id), obj = windowMap[key];
                if (!obj) { obj = windowComponent.createObject(root, { data: data }); membershipChanged = true; }
                else if (JSON.stringify(obj.data) !== JSON.stringify(data)) obj.data = data;
                live[key] = obj; ordered.push(obj);
                if (obj.activated) active = obj;
            }
            for (var old in windowMap) if (!live[old]) retired.push(windowMap[old]);
            if (membershipChanged || retired.length > 0) windowMap = live;
            // Preserve array and object identities for title/focus/layout events.
            if (list.length !== ordered.length || ordered.some((w, n) => list[n] !== w)) toplevels.values = ordered;
            list = toplevels.values;
            activeToplevel = active;
            clients = state.windows;
            windowsKey = nextWindows;
        }
        if (monitorsKey !== nextMonitors) { monitorData = state.monitors; monitorsKey = nextMonitors; }
        if (keyboardKey !== nextKeyboard) { keyboard = state.keyboard; keyboardKey = nextKeyboard; }
        overview = state.overview;
        if (workspacesKey !== nextWorkspaces) {
            var ws = [], focus = null;
            for (i = 0; i < state.workspaces.length; i++) {
                var w = state.workspaces[i], members = list.filter(function(t) { return t.data.workspace_id === w.id; });
                var item = { id: w.id, idx: w.idx, name: w.name || String(w.idx), output: w.output,
                             focused: w.is_focused, active: w.is_active, toplevels: { values: members } };
                ws.push(item); if (w.is_focused) focus = item;
            }
            workspaces.values = ws;
            focusedWorkspace = focus;
            workspacesKey = nextWorkspaces;
        }
        focusedMonitor = focusedWorkspace ? monitorData.find(function(m) { return m.name === root.focusedWorkspace.output; }) || null : null;
        updated();
        retired.forEach(function(w) { w.destroy(1000); });
    }
    Process {
        id: bridge
        command: ["python3", "-u", root.helper]
        running: true
        stdinEnabled: true
        stdout: SplitParser { onRead: line => { try { root.accept(JSON.parse(line)); } catch (e) { console.warn("[niri] " + e); } } }
        onExited: { root.connected = false; root.stateKey = ""; restart.restart(); }
    }
    Timer { id: restart; interval: 2000; onTriggered: bridge.running = true }
}

import QtQuick
import Quickshell
import "../MacShell" as Port

ShellRoot {
    id: test
    property bool passed: false
    property int updates: 0
    Connections { target: Port.Niri; function onUpdated() { test.updates++; } }
    function state(title) {
        return {connected: true, state: {
            windows: [{id: 42, app_id: "test", title: title, is_focused: true, workspace_id: 3, workspace: {id: 3}, output: "virtual", fullscreen: 0}],
            monitors: [{name: "virtual"}],
            workspaces: [{id: 3, idx: 1, name: null, output: "virtual", is_active: true, is_focused: true}],
            keyboard: {names: ["English (US)"], current_idx: 0}, overview: false
        }};
    }
    Component.onCompleted: {
        Port.NiriCapture.frames = {"42": {url: "unused", width: 1, height: 1}};
        Port.NiriCapture.enabled = false;
        if (Object.keys(Port.NiriCapture.frames).length !== 0) throw new Error("Paused captures retained stale frames");
        Port.Niri.accept(state("First"));
        var window = Port.Niri.activeToplevel;
        if (window.title !== "First") throw new Error("Initial window title was lost");
        var monitors = Port.Niri.monitorData, workspaces = Port.Niri.workspaces.values, clients = Port.Niri.clients;
        var windows = Port.Niri.windowMap, keyboard = Port.Niri.keyboard, updateCount = test.updates;
        Port.Niri.accept(state("First"));
        if (test.updates !== updateCount || clients !== Port.Niri.clients) throw new Error("An unchanged snapshot notified consumers");
        for (var n = 0; n < 20; n++) Port.Niri.accept({connected: true, titles: {"42": "Streaming " + n, "999": "Already closed"}});
        if (window.title !== "Streaming 19" || window.lastIpcObject.title !== "Streaming 19" || Port.Niri.clients[0].title !== "Streaming 19")
            throw new Error("Title deltas did not update the public window title: " + JSON.stringify([window.title, window.lastIpcObject.title, Port.Niri.clients[0].title]));
        if (test.updates !== updateCount || clients !== Port.Niri.clients || monitors !== Port.Niri.monitorData || workspaces !== Port.Niri.workspaces.values)
            throw new Error("Title deltas invalidated geometry/workspace models");
        Port.NiriCapture.frames = {"42": {url: "unused", width: 1, height: 1}};
        Port.NiriCapture.acceptFrame({id: 42, error: "Expected fixture capture failure"});
        if (Port.NiriCapture.frames["42"]) throw new Error("Failed capture retained its old frame");
        Port.NiriCapture.acceptFrame({id: 999, url: "closed", width: 1, height: 1});
        if (Port.NiriCapture.frames["999"]) throw new Error("A late frame revived a closed window");
        Port.NiriCapture.acceptFrame({id: 42, url: "paused", width: 1, height: 1});
        if (Port.NiriCapture.frames["42"]) throw new Error("A late frame revived a paused capture");
        Port.Niri.accept(state("Renamed"));
        if (window !== Port.Niri.activeToplevel || window.id !== 42 || window.title !== "Renamed") throw new Error("Window identity/focus failed");
        if (monitors !== Port.Niri.monitorData || workspaces !== Port.Niri.workspaces.values || windows !== Port.Niri.windowMap || keyboard !== Port.Niri.keyboard)
            throw new Error("A title update replaced unrelated models");
        var changed = state("Renamed"); changed.state.keyboard.current_idx = 1;
        clients = Port.Niri.clients;
        Port.NiriCapture.frames = {"42": {url: "unused", width: 1, height: 1}};
        var frames = Port.NiriCapture.frames;
        Port.Niri.accept(changed);
        if (clients !== Port.Niri.clients || frames !== Port.NiriCapture.frames || workspaces !== Port.Niri.workspaces.values)
            throw new Error("A keyboard update invalidated window/capture/workspace models");
        if (Port.Niri.workspaceLabel(3) !== "1") throw new Error("Workspace ID/index mapping failed");
        preview.captureSource = window;
        if (preview.hasContent) throw new Error("A window without a captured frame must use the icon fallback");
        changed.state.windows = [];
        Port.Niri.accept(changed);
        if (Port.NiriCapture.frames["42"] || Port.Niri.activeToplevel || Port.Niri.workspaces.values[0].toplevels.values.length !== 0)
            throw new Error("Closed window survived model/capture pruning");
        Port.Niri.accept({connected: true, titles: {"42": "Late title"}});
        if (Port.Niri.windowMap["42"] || Port.Niri.clients.length !== 0) throw new Error("A late title revived a closed window");
        test.passed = true;
        console.log("MACSHELL_ADAPTER_PASS");
    }
    Port.NiriPreview { id: preview; live: false; visible: false }
    Timer { interval: 200; running: true; onTriggered: Qt.exit(test.passed ? 0 : 1) }
}

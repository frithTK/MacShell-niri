import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
import "." as Port

ShellRoot {
    id: root
    property int phase: 0
    property int cycles: 0
    property int waits: 0
    property bool mounted: true
    property bool active: true
    property bool mirrorShown: false
    property bool overview: false
    property var clients: []
    readonly property int positionSignals: widgets.testPositionSignals
    property int heldSignals: 0
    property double weatherTime: 0
    property int acquiredAtLoop: 0
    property int releasedAtLoop: 0
    QtObject { id: output; property string name: "DP-1"; property real width: 1920; property real height: 1080 }
    Port.MacWidgets {
        id: widgets; screens: [output]; outputs: [{name: "DP-1", serial: "one"}]
        visibilityClients: root.clients; visibilityConnected: true; overviewOpen: root.overview
    }
    FileView {
        id: weatherStarted; path: Quickshell.env("MACSHELL_WIDGET_TEST_JOBS") + "/weather.started.json"
        preload: true; watchChanges: true; onFileChanged: reload()
    }
    FileView {
        id: lyricsStarted; path: Quickshell.env("MACSHELL_WIDGET_TEST_JOBS") + "/lyrics.started.json"
        preload: true; watchChanges: true; onFileChanged: reload()
    }
    FileView {
        id: lastWeather; path: Quickshell.env("MACSHELL_WIDGET_TEST_JOBS") + "/weather.json"
        preload: true; watchChanges: true; onFileChanged: reload()
    }
    Window {
        width: 1700; height: 900; visible: true
        Item {
            id: scene; anchors.fill: parent
            Repeater {
                model: root.mounted && widgets.widgetsEnabled ? [false, true] : []
                delegate: Item {
                    required property bool modelData
                    readonly property bool mirror: modelData
                    Repeater {
                        model: widgets.renderedRows
                        delegate: Item {
                            id: row
                            required property var modelData
                            Port.WidgetVisual {
                                objectName: (parent.parent.mirror ? "mirror_" : "desktop_") + row.modelData.wid
                                host: widgets; instanceId: row.modelData.wid; mirror: parent.parent.mirror
                                wtype: row.modelData.wtype; wstyle: row.modelData.wstyle; wsize: row.modelData.wsize
                                wmode: row.modelData.wmode; wappearance: row.modelData.wappearance
                                sname: row.modelData.woutput; x: row.modelData.wx; y: row.modelData.wy
                                width: widgets.dims(wsize)[0]; height: widgets.dims(wsize)[1]
                                renderActive: root.active && (!mirror || root.mirrorShown) && widgets.outputActive(sname)
                            }
                        }
                    }
                }
            }
        }
    }
    function check(value, reason) { if (!value) throw new Error(reason); }
    function requestStarted(file, pid, epoch) {
        if (!pid) return false;
        try {
            var record = JSON.parse(file.text());
            return record.pid === pid && record.epoch === epoch;
        } catch (error) { return false; }
    }
    function find(item, name) {
        if (item.objectName === name) return item;
        for (var child of item.children || []) { var result = find(child, name); if (result) return result; }
        return null;
    }
    function empty(state) {
        return !state.positionPolling && !state.clock.running && state.activeViews === 0
            && Object.keys(state.sources).every(key => state.sources[key] === 0);
    }
    Timer {
        interval: 40; repeat: true; running: true
        onTriggered: {
            if (++root.waits > 900) { console.error("LIFECYCLE_TIMEOUT phase " + root.phase + " " + JSON.stringify(widgets.resourceState())); Qt.exit(1); return; }
            if (!widgets.ready || widgets.pending) return;
            try {
                var state = widgets.resourceState();
                if (root.phase === 0) {
                    if (state.views !== 10) return;
                    root.check(state.consumers.length === 5 && state.sources.time === 2 && state.sources.weather === 1, "one consumer per ID");
                    root.mirrorShown = true; root.phase++;
                } else if (root.phase === 1) {
                    if (!widgets.wxReady) return;
                    root.check(state.activeViews === 10 && state.consumers.length === 5 && state.sources.weather === 1, "mirrors do not double source subscriptions");
                    root.weatherTime = widgets.weatherUpdatedAt;
                    widgets.setWidgetLyrics("p", true); root.phase++;
                } else if (root.phase === 2) {
                    if (widgets.lyricsState !== "ok") return;
                    root.check(state.sources.lyrics === 1 && state.positionInterval === 250, "one lyrics consumer and one fast position timer");
                    root.check(root.find(scene, "desktop_p").visual.lyricsView && root.find(scene, "mirror_p").visual.lyricsView, "lyrics view matches its mirror");
                    widgets.fetchLyrics(); root.phase = 18;
                } else if (root.phase === 18) {
                    if (!root.requestStarted(lyricsStarted, state.lyricsPid, widgets.lyricsEpoch)) return;
                    root.active = false; root.phase = 3;
                } else if (root.phase === 3) {
                    root.check(root.empty(state) && !state.weatherScheduled, "culling stops clock, position and refresh sources");
                    root.heldSignals = root.positionSignals;
                    widgets.testPlayer.trackTitle = "New track"; widgets.testPlayer.position = 42;
                    root.check(root.find(scene, "desktop_p").playerData.title !== "New track", "inactive snapshots stay frozen");
                    root.phase++;
                } else if (root.phase === 4) {
                    if (root.waits % 8 !== 0) return;
                    root.check(!state.weatherPid && !state.lyricsPid, "culling terminates owned request processes");
                    root.check(root.positionSignals <= root.heldSignals + 1, "inactive player does not poll position");
                    root.active = true; root.phase++;
                } else if (root.phase === 5) {
                    root.check(root.find(scene, "desktop_p").playerData.title === "New track" && root.find(scene, "desktop_p").playerData.position === 42, "resume refreshes current metadata");
                    root.check(widgets.weatherUpdatedAt === root.weatherTime && !state.weatherPid, "fresh weather cache survives hiding");
                    root.clients = [{output: "DP-1", geometryKnown: true, fullscreen: 1, workspaceActive: true, mapped: true, hidden: false}]; root.phase++;
                } else if (root.phase === 6) {
                    root.check(root.empty(state), "known fullscreen culls desktop and mirror");
                    root.overview = true; root.phase++;
                } else if (root.phase === 7) {
                    root.check(state.sources.time === 2, "overview restores widget updates");
                    root.overview = false; root.clients = [Object.assign({}, root.clients[0], {geometryKnown: false})]; root.phase++;
                } else if (root.phase === 8) {
                    root.check(state.sources.time === 2, "unknown geometry remains active");
                    root.clients = []; root.check(widgets.setWidgetsEnabled(false), "disable widgets accepted"); root.phase++;
                } else if (root.phase === 9) {
                    if (state.views) return;
                    root.check(root.empty(state) && !state.weatherPid && !state.lyricsPid, "disabled widgets release every owned worker");
                    root.check(widgets.setWidgetsEnabled(true), "enable widgets accepted"); root.phase++;
                } else if (root.phase === 10) {
                    if (state.views !== 10 || !widgets.wxReady) return;
                    widgets.setWidgetLyrics("p", false); root.mounted = false;
                    root.phase++;
                } else if (root.phase === 11) {
                    if (state.views || state.weatherPid || state.lyricsPid) return;
                    root.acquiredAtLoop = state.acquired; root.releasedAtLoop = state.released;
                    root.mounted = true; root.phase++;
                } else if (root.phase === 12) {
                    if (!state.sources.weather) return;
                    widgets.refresh(); root.phase++;
                } else if (root.phase === 13) {
                    if (!root.requestStarted(weatherStarted, state.weatherPid, widgets.weatherEpoch)) return;
                    root.mounted = false; root.phase++;
                } else if (root.phase === 14) {
                    if (state.views || state.weatherPid || state.lyricsPid) return;
                    root.check(root.empty(state) && widgets.wxTemp !== 999, "cancelled response cannot revive unmounted consumers");
                    if (++root.cycles < 20) { root.mounted = true; root.phase = 12; }
                    else root.phase++;
                } else if (root.phase === 15) {
                    root.check(state.acquired - root.acquiredAtLoop === 200 && state.released - root.releasedAtLoop === 200, "twenty real visual mount/unmount cycles balance 200 references");
                    root.mounted = true; root.phase++;
                } else if (root.phase === 16) {
                    if (!state.sources.weather) return;
                    var old = JSON.parse(lastWeather.text());
                    if (!old.result) return;
                    root.check(old.epoch !== widgets.weatherEpoch, "stale response generation differs");
                    old.result.forecast.current.temperature_2m = 999; widgets.acceptWeather(JSON.stringify(old));
                    root.check(widgets.wxTemp !== 999, "late weather response rejected even after re-mount");
                    root.mounted = false; root.phase++;
                } else if (root.phase === 17) {
                    if (state.views || state.weatherPid || state.lyricsPid) return;
                    root.check(state.acquired === state.released && root.empty(state), "all consumers and workers released at completion");
                    console.log("MACSHELL_WIDGET_LIFECYCLE_PASS: shared data/time, mirrors, freeze/resume, fullscreen/overview, disable/enable, late responses and 20 mount/unmount cycles"); Qt.quit();
                }
            } catch (error) { console.error("phase " + root.phase + ": " + error); Qt.exit(1); }
        }
    }
}

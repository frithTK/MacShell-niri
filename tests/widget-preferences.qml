import QtQuick
import Quickshell
import "." as Port
import "WidgetLayout.js" as Layout

ShellRoot {
    id: root
    property int phase: 0
    property string token: ""
    property int secondStates: 0
    property int stableStates: 0
    Port.WidgetPreferences { id: first; origin: ({name: "DP-1", width: 1920, height: 1080, serial: "one"}) }
    Port.WidgetPreferences { id: second; origin: ({name: "DP-1", width: 1920, height: 1080, serial: "one"}); onChanged: root.secondStates++ }
    function check(ok, reason) { if (!ok) throw new Error(reason); }
    Timer {
        interval: 100; repeat: true; running: true
        onTriggered: {
            try {
                if (!first.ready || !second.ready || first.pending || second.pending || first.loading || second.loading) return;
                if (root.phase === 0) {
                    var next = Layout.clone(first.values);
                    next.desktopOutput = "main"; next.outputs.main = {identity: {connector: "DP-1", serial: "one"}}; next.bindings["DP-1"] = "main";
                    next.widgets = [{id: "clock", type: "clock", version: 1, output: "main", position: {column: 0, row: 0}, settings: {size: "small"}}, {id: "future", type: "agenda", version: 99, custom: [0, false]}];
                    check(first.save(next), "initial save accepted"); root.phase++;
                } else if (root.phase === 1) {
                    check(first.values.widgets.length === 2, first.error);
                    check(second.save(Layout.clone(second.values)), "stale writer submits"); root.phase++;
                } else if (root.phase === 2) {
                    check(second.error.indexOf("changed elsewhere") >= 0, "stale writer rejected");
                    check(second.values.widgets.length === 2, "conflict returns current records");
                    second.refresh(); root.phase++;
                } else if (root.phase === 3) {
                    check(second.token === first.token, "reload catches up");
                    var next = Layout.clone(second.values); next.defaults.tempUnit = "F";
                    check(second.save(next), "defaults save accepted"); root.phase++;
                } else if (root.phase === 4) {
                    check(second.values.defaults.tempUnit === "F", second.error);
                    check(first.save(Layout.clone(first.values)), "first draft now stale"); root.phase++;
                } else if (root.phase === 5) {
                    check(first.error.indexOf("changed elsewhere") >= 0, "reverse conflict rejected");
                    first.refresh(); root.phase++;
                } else if (root.phase === 6) {
                    check(first.token === second.token, "both owners caught up");
                    root.token = first.token; check(first.save(Layout.clone(first.values)), "noop accepted"); root.phase++;
                } else if (root.phase === 7) {
                    check(first.token === root.token, "noop makes no write");
                    second.origin = {name: "DP-2", width: 800, height: 600, serial: "two"}; root.phase++;
                } else if (root.phase === 8) {
                    check(second.token === root.token, "different origin makes no write");
                    check(second.values.outputs.main.identity.connector === "DP-1", "desktop identity is retained");
                    check(JSON.stringify(second.values.widgets[1].custom) === "[0,false]", "future instance preserved");
                    root.stableStates = root.secondStates;
                    second.origin = Layout.clone(second.origin); root.phase++;
                } else {
                    check(root.stableStates === root.secondStates, "identical output snapshots do not reload the file");
                    console.log("MACSHELL_WIDGET_PREFERENCES_PASS"); Qt.quit();
                }
            } catch (error) { console.error(error); Qt.exit(1); }
        }
    }
}

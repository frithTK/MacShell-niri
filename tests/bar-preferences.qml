import QtQuick
import Quickshell
import "." as Port
import "BarLayout.js" as Layout
import "OutputProfiles.js" as Outputs

ShellRoot {
    property int stage: 0
    function check(condition, message) { if (!condition) { console.error("BAR_LAYOUT_FAIL: " + message); Qt.exit(1); } }
    function begin() {
        if (stage || !first.ready || !second.ready) return;
        check(first.values.common.length === 15 && first.catalog.length === 16, "catalog and migration");
        check(!first.commonEnabled("tray") && first.commonEnabled("clock"), "legacy visibility");
        for (var width of [800, 1366, 1920]) for (var scale of [1, 1.25, 1.5]) {
            var plan = Layout.solve(first.values.common, first.catalog, {appMenus: {preferred: 1600, forms: [1600, 100]}, tray: {preferred: 520}}, width / scale);
            var boxes = Object.keys(plan.items).map(key => plan.items[key]).filter(item => item.width > 0).sort((a, b) => a.x - b.x);
            var end = 0;
            boxes.forEach(item => { check(item.x >= end && item.x + item.width <= width / scale, "width budget"); end = item.x + item.width; });
            check(!plan.overflow.length || plan.overflowX >= end, "overflow budget");
        }
        stage = 1;
        var next = Layout.clone(first.values);
        next.outputs.saved = {identity: {connector: "DP-1", make: "Demo", model: "Display", serial: "one"}, layout: []};
        first.save(next, first.token);
    }
    Port.BarPreferences {
        id: first
        legacy: ({showTray: false})
        onReadyChanged: begin()
        onFinished: success => {
            if (stage === 1) {
                check(success && !pending, "saved layout"); stage = 2;
                check(Outputs.effective(values, {name: "DP-1", serial: "one"}, [{name: "DP-1", serial: "one"}]).length === 0, "empty override");
                second.save(second.values, second.token);
            } else if (stage === 3) {
                check(success && !values.outputs.saved.layout, "inherit removes override");
                check(values.outputs.saved.identity.serial === "one", "disconnected identity retained");
                console.log("MACSHELL_BAR_PREFERENCES_PASS"); Qt.quit();
            }
        }
    }
    Port.BarPreferences {
        id: second
        legacy: ({showTray: false})
        onReadyChanged: begin()
        onFinished: success => {
            if (stage !== 2) return;
            check(!success && error.indexOf("changed elsewhere") >= 0, "conflict retains other display");
            stage = 3;
            var next = Layout.clone(first.values); delete next.outputs.saved.layout;
            first.save(next, first.token);
        }
    }
    Timer { interval: 8000; running: true; onTriggered: { console.error("BAR_LAYOUT_FAIL: timeout " + stage); Qt.exit(1); } }
}

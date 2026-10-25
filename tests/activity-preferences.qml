import QtQuick
import Quickshell
import "." as Port

ShellRoot {
    property int stage: 0
    property string staleToken: ""
    function check(condition, reason) {
        if (!condition) { console.error("ACTIVITY_PREFERENCES_FAIL: " + reason); Qt.exit(1); }
    }
    function begin() {
        if (stage !== 0 || !first.ready || !second.ready) return;
        check(first.values.cpuWarning === 65, "defaults");
        check(first.fields.length === 7, "schema");
        staleToken = second.token;
        stage = 1;
        first.save(Object.assign({}, first.values, {cpuWarning: 45}), first.token);
    }
    Port.ActivityPreferences {
        id: first
        onReadyChanged: begin()
        onFinished: success => {
            if (stage === 1) {
                check(success && !pending && values.cpuWarning === 45, "commit response");
                stage = 2;
                second.save(Object.assign({}, second.values, {cpuWarning: 50}), staleToken);
            } else if (stage === 3) {
                check(success && values.cpuWarning === 45 && !pending, "unchanged commit");
                stage = 4;
            } else if (stage === 4) {
                check(success && values.cpuWarning === 65 && !pending, "queued reset");
                console.log("MACSHELL_ACTIVITY_PREFERENCES_PASS");
                Qt.quit();
            }
        }
    }
    Port.ActivityPreferences {
        id: second
        onReadyChanged: begin()
        onFinished: success => {
            if (stage !== 2) return;
            check(!success && !pending && values.cpuWarning === 45 && error.indexOf("changed elsewhere") >= 0, "conflict response");
            stage = 3;
            first.save(first.values, first.token);
            first.resetToDefaults();
        }
    }
    Timer { interval: 8000; running: true; onTriggered: { console.error("ACTIVITY_PREFERENCES_FAIL: timeout at stage " + stage); Qt.exit(1); } }
}

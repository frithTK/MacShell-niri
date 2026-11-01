import QtQuick
import QtQuick.Window
import QtTest
import Quickshell
import "." as Port

ShellRoot {
    id: root
    property int phase: 0
    function find(item, name) {
        if (!item) return null;
        if (item.objectName === name) return item;
        for (var child of item.children || []) {
            var found = find(child, name);
            if (found) return found;
        }
        return null;
    }
    Port.ClockClient {
        id: client
        enabled: true
        storePath: Quickshell.env("MACSHELL_CLOCK_TEST_STORE")
        onCompleted: (success, result, error) => {
            if (!success) { console.error("CLOCK_RECOVERY_FAIL command " + error); Qt.exit(1); }
        }
    }
    Window {
        id: testWindow
        width: 620; height: 550; visible: true
        Port.ClockSnoozeRecovery { id: pane; x: 20; y: 20; width: 580; clock: client }
        TestEvent { id: events }
    }
    Timer {
        interval: 50; running: true; repeat: true
        onTriggered: {
            if (!client.ready || client.busy) return;
            if (root.phase === 0 && pane.entries.length === 2) {
                var resume = root.find(pane, "snoozeResume-" + pane.entries[0].id);
                if (!resume) return;
                root.phase = 1;
                testWindow.contentItem.grabToImage(function() {
                    events.mouseClick(resume, resume.width / 2, resume.height / 2, Qt.LeftButton, Qt.NoModifier, 0);
                });
            } else if (root.phase === 1 && pane.entries.length === 1) {
                var discard = root.find(pane, "snoozeDiscard-" + pane.entries[0].id);
                if (!discard) return;
                root.phase = 2;
                testWindow.contentItem.grabToImage(function() {
                    events.mouseClick(discard, discard.width / 2, discard.height / 2, Qt.LeftButton, Qt.NoModifier, 0);
                });
            } else if (root.phase === 2 && pane.entries.length === 0) {
                console.log("CLOCK_RECOVERY_INTEGRATION_PASS"); Qt.exit(0);
            }
        }
    }
    Timer { interval: 5000; running: true; onTriggered: { console.error("CLOCK_RECOVERY_FAIL timeout phase=" + root.phase + " ready=" + client.ready + " busy=" + client.busy + " entries=" + pane.entries.length + " array=" + (client.snapshot && Array.isArray(client.snapshot.timing.legacySnoozesRecovery)) + " same=" + (pane.clock === client) + " snapshot=" + JSON.stringify(client.snapshot) + " error=" + client.error + " service=" + client.serviceError); Qt.exit(1); } }
}

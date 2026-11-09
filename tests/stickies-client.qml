import QtQuick
import Quickshell
import "." as Port

ShellRoot {
    id: root
    property int phase: 0
    Port.JsonService { id: shared; script: "notes_service.py"; launcher: "notes-service.sh"; arguments: ["--store", Quickshell.env("MACSHELL_NOTES_TEST_STORE")]; enabled: true }
    Port.NotesController { id: first; enabled: true; sharedService: shared; selectFirst: false }
    Port.NotesController { id: second; enabled: true; sharedService: shared; selectFirst: false }
    Timer {
        interval: 30; repeat: true; running: true
        onTriggered: {
            if (root.phase === 0 && first.ready && second.ready && !first.busy && !second.busy) {
                if (!first.create()) { console.error("STICKIES_CLIENT_FAIL first create"); Qt.exit(1); return; }
                root.phase = 1;
            } else if (root.phase === 1 && first.selectedId && !first.busy && !second.busy) {
                if (!second.create()) { console.error("STICKIES_CLIENT_FAIL second create"); Qt.exit(1); return; }
                root.phase = 2;
            } else if (root.phase === 2 && second.selectedId && !second.busy) {
                first.edit("Первая записка"); first.flush();
                second.edit("Вторая записка"); second.flush();
                root.phase = 3;
            } else if (root.phase === 3 && first.ready && second.ready && !first.busy && !second.busy && !first.dirty && !second.dirty) {
                if (first.error || second.error || first.body !== "Первая записка" || second.body !== "Вторая записка" || first.revision !== 1 || second.revision !== 1) {
                    console.error("STICKIES_CLIENT_FAIL recovery " + first.error + " / " + second.error); Qt.exit(1); return;
                }
                console.log("STICKIES_CLIENT_PASS"); Qt.exit(0);
            }
        }
    }
    Timer { interval: 12000; running: true; onTriggered: { console.error("STICKIES_CLIENT_FAIL timeout " + root.phase); Qt.exit(1); } }
}

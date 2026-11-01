import QtQuick
import Quickshell
import "." as Port

ShellRoot {
    id: root
    property int phase: 0
    Port.NotesController {
        id: notes
        enabled: true
        storePath: Quickshell.env("MACSHELL_NOTES_TEST_STORE")
    }
    Timer {
        interval: 30; repeat: true; running: true
        onTriggered: {
            if (root.phase === 0 && notes.ready && !notes.busy) {
                if (!notes.create()) { console.error("NOTES_CLIENT_FAIL create"); Qt.exit(1); return; }
                root.phase = 1;
            } else if (root.phase === 1 && notes.selectedId && !notes.busy) {
                notes.edit("Первое сохранение"); notes.flush();
                notes.edit("Последнее изменение 🌍");
                root.phase = 2;
            } else if (root.phase === 2 && notes.ready && !notes.busy && !notes.dirty) {
                if (notes.error || notes.body !== "Последнее изменение 🌍" || notes.revision !== 2) {
                    console.error("NOTES_CLIENT_FAIL state " + notes.error + " revision=" + notes.revision); Qt.exit(1); return;
                }
                console.log("NOTES_CLIENT_PASS"); Qt.exit(0);
            }
        }
    }
    Timer { interval: 12000; running: true; onTriggered: { console.error("NOTES_CLIENT_FAIL timeout phase=" + root.phase + " ready=" + notes.ready + " error=" + notes.error); Qt.exit(1); } }
}

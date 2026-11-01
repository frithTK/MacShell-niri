import QtQuick
import Quickshell
import "." as Port

ShellRoot {
    id: root
    property int phase: 0
    Port.RemindersController { id: tasks; enabled: true; storePath: Quickshell.env("MACSHELL_REMINDERS_TEST_STORE") }
    Timer {
        interval: 30; repeat: true; running: true
        onTriggered: {
            if (root.phase === 0 && tasks.ready && !tasks.busy && tasks.lists.length) {
                if (!tasks.createTask("Проверка 🌿")) { console.error("REMINDERS_CLIENT_FAIL submit"); Qt.exit(1); return; }
                root.phase = 1;
            } else if (root.phase === 1 && tasks.ready && !tasks.busy && tasks.tasks.length) {
                if (tasks.error || tasks.tasks.length !== 1 || tasks.tasks[0].title !== "Проверка 🌿") {
                    console.error("REMINDERS_CLIENT_FAIL state " + tasks.error); Qt.exit(1); return;
                }
                console.log("REMINDERS_CLIENT_PASS"); Qt.exit(0);
            }
        }
    }
    Timer { interval: 12000; running: true; onTriggered: { console.error("REMINDERS_CLIENT_FAIL timeout phase=" + root.phase + " error=" + tasks.error); Qt.exit(1); } }
}

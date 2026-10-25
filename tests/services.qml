import QtQuick
import Quickshell
import Quickshell.Wayland
import "." as Port
ShellRoot {
    IdleInhibitor { enabled: false }
    Port.SystemStats { id: stats; enabled: false }
    Port.WifiControl { active: false }
    Port.TimedModes { enabled: false }
    Port.NightShiftControl { active: false }
    Port.RecordingControl { active: false }
    Timer { interval: 200; running: true; onTriggered: { console.log("MACSHELL_SERVICES_PASS"); Qt.exit(0); } }
}

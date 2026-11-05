// Independent preview of Stickies from this checkout; does not update the shell.
import QtQuick
import Quickshell
import Quickshell.Io
import "." as Port
import "Locale" as Language

ShellRoot {
    id: root
    property bool started: false
    settings.watchFiles: false
    Language.LocaleRuntime {}
    Port.StickiesApp {
        id: app
        Component.onCompleted: { app.open(); root.started = true; }
        onWindowsChanged: if (root.started && windows.length === 0) Qt.quit()
    }
    IpcHandler {
        target: "stickiesPreview"
        function state(): string {
            return JSON.stringify({count: app.windows.length, ready: app.windows.length > 0 && app.windows.every(w => w.controller.ready && !w.controller.busy && !!w.controller.selectedId)});
        }
        function open(): void { app.open(); }
        function close(): void { app.windows.slice().forEach(w => w.requestClose()); }
    }
}

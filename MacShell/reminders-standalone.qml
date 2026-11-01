// Independent preview of task lists from this checkout; does not update the shell.
import QtQuick
import Quickshell
import Quickshell.Io
import "." as Port
import "Locale" as Language

ShellRoot {
    id: root
    settings.watchFiles: false
    Language.LocaleRuntime {}
    Port.RemindersApp {
        id: app
        Component.onCompleted: app.open()
    }
    IpcHandler {
        target: "remindersPreview"
        function state(): string { return JSON.stringify({visible: app.window.visible, ready: app.controller.ready, busy: app.controller.busy}); }
        function open(): void { app.open(); }
        function close(): void { app.requestClose(); }
        function shutdown(): void { if (!app.window.visible && !app.controller.busy) Qt.quit(); }
    }
}

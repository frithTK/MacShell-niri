// A separate Notes window for trying the current checkout without updating the shell.
import QtQuick
import Quickshell
import Quickshell.Io
import "." as Port
import "Locale" as Language

ShellRoot {
    id: root
    property bool opened: false
    Language.LocaleRuntime {}
    Port.NotesApp {
        id: app
        Component.onCompleted: { app.open(); root.opened = true; }
    }
    Connections {
        target: app.window
        function onVisibleChanged() { if (root.opened && !app.window.visible) Qt.quit(); }
    }
    IpcHandler {
        target: "notesPreview"
        function state(): string { return JSON.stringify({visible: app.window.visible, ready: app.controller.ready, busy: app.controller.busy}); }
        function close(): void { app.requestClose(); }
    }
}

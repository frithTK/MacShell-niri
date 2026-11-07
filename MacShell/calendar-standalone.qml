// Independent preview of the checkout; it uses the configured calendar database.
import QtQuick
import Quickshell
import Quickshell.Io
import "." as Port
import "Locale" as Language

ShellRoot {
    id: root
    settings.watchFiles: false
    property bool opened: false
    Language.LocaleRuntime {}
    Port.CalendarApp { id: app; Component.onCompleted: { app.open(); root.opened = true; } }
    Connections { target: app.window; function onVisibleChanged() { if (root.opened && !app.window.visible) Qt.quit(); } }
    IpcHandler {
        target: "calendarPreview"
        function state(): string { return JSON.stringify({visible: app.window.visible, ready: app.controller.ready, busy: app.controller.busy}); }
        function open(): void { app.open(); }
        function close(): void { app.requestClose(); }
    }
}

import QtQuick

QtObject {
    property bool connected: false
    property bool gaming: false
    property bool recording: false
    property bool windowPreviews: true
    property bool barGlass: false
    property bool dockGlass: false
    readonly property bool enabled: connected && !gaming && !recording && (windowPreviews || barGlass || dockGlass)
}

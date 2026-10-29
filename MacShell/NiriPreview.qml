import QtQuick

// Same view contract as ScreencopyView; frames are shared per niri window ID.
Item {
    id: view
    property var captureSource: null
    property bool live: true
    property bool paintCursor: false
    property size constraintSize: Qt.size(512, 512)
    readonly property var frame: captureSource && captureSource.id ? NiriCapture.frames[String(captureSource.id)] || null : null
    // Image retains the previous pixels while an updated frame loads. Keep the
    // preview visible during that interval, but never reuse another window's
    // frame or a frame that the capture service has explicitly discarded.
    property string loadedWindowId: ""
    readonly property string windowId: captureSource && captureSource.id ? String(captureSource.id) : ""
    readonly property bool hasContent: frame !== null && windowId !== "" && loadedWindowId === windowId &&
        (image.status === Image.Ready || image.status === Image.Loading)
    readonly property size sourceSize: Qt.size(frame ? frame.width : 0, frame ? frame.height : 0)
    implicitWidth: frame ? frame.width : 0
    implicitHeight: frame ? frame.height : 0
    function captureFrame() { if (visible) NiriCapture.request(captureSource); }
    onWindowIdChanged: loadedWindowId = ""
    onCaptureSourceChanged: if (captureSource) Qt.callLater(captureFrame)
    onVisibleChanged: if (visible) Qt.callLater(captureFrame)
    onLiveChanged: if (live) Qt.callLater(captureFrame)
    Image {
        id: image
        anchors.fill: parent
        source: view.frame ? view.frame.url : ""
        cache: false
        asynchronous: true
        retainWhileLoading: true
        onStatusChanged: {
            if (status === Image.Ready) view.loadedWindowId = view.windowId;
            else if (status === Image.Error || status === Image.Null) view.loadedWindowId = "";
        }
    }
    Timer { interval: NiriCapture.frameInterval; running: view.visible && view.live && view.captureSource !== null; repeat: true; triggeredOnStart: true; onTriggered: view.captureFrame() }
}

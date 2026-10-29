import QtQuick
import Quickshell
import "." as Port

ShellRoot {
    id: test
    property int phase: 0
    property int reloads: 0
    property bool passed: false
    property string first: Quickshell.env("MACSHELL_PREVIEW_FIRST")
    property string second: Quickshell.env("MACSHELL_PREVIEW_SECOND")
    property var one: ({id: 42})
    property var two: ({id: 43})
    function frame(id, url) {
        var frames = Object.assign({}, Port.NiriCapture.frames);
        frames[String(id)] = {url: url, width: 2048, height: 2048};
        Port.NiriCapture.frames = frames;
    }
    function fail(message) { console.error("MACSHELL_PREVIEW_RELOAD_FAIL: " + message); Qt.exit(1); }
    Component.onCompleted: {
        Port.NiriCapture.enabled = false;
        preview.captureSource = one;
        frame(42, first);
    }
    Window {
        visible: true; width: 120; height: 120
        Port.NiriPreview { id: preview; anchors.fill: parent; live: false }
    }
    Connections {
        target: preview
        function onHasContentChanged() {
            if (test.phase === 1 && !preview.hasContent)
                test.fail("A loaded window fell back to its icon while the next frame loaded");
        }
    }
    Connections {
        target: preview.children[0]
        function onStatusChanged() {
            if (target.status === Image.Loading && test.phase === 1) {
                test.reloads++;
            }
        }
    }
    Timer {
        interval: 40; running: true; repeat: true
        onTriggered: {
            var image = preview.children[0];
            if (test.phase === 0 && preview.hasContent) {
                test.phase = 1;
                test.frame(42, test.second);
            } else if (test.phase === 1 && test.reloads > 0 && image.status === Image.Ready) {
                test.phase = 2;
                preview.captureSource = test.two;
                if (preview.hasContent) test.fail("The previous window's frame appeared for a new source");
                test.frame(43, test.first);
            } else if (test.phase === 2 && preview.hasContent) {
                test.phase = 3;
                test.frame(43, "file:///nonexistent-macshell-preview-image.png");
            } else if (test.phase === 3 && image.status === Image.Error) {
                if (preview.hasContent) test.fail("An invalid frame did not fall back to its icon");
                test.frame(43, test.second);
                test.phase = 4;
            } else if (test.phase === 4 && preview.hasContent) {
                Port.NiriCapture.frames = {};
                if (preview.hasContent) test.fail("A discarded frame remained visible");
                test.passed = true;
                console.log("MACSHELL_PREVIEW_RELOAD_PASS: retained image on refresh, source isolation, error and removal");
                Qt.exit(0);
            }
        }
    }
    Timer { interval: 9000; running: true; onTriggered: if (!test.passed) test.fail("Timed out in phase " + test.phase + ", reloads " + test.reloads) }
}

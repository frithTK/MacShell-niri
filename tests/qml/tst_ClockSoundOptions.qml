import QtQuick
import QtQuick.Controls
import QtTest
import "../../MacShell" as Port

TestCase {
    id: test
    name: "ClockSoundOptions"; when: windowShown
    width: 640; height: 520; visible: true
    Component {
        id: clientComponent
        QtObject {
            property string previewId: ""
            property string soundError: ""
            property var previewOptions: null
            property string previewKind: ""
            function previewSound(id, options, kind) { previewId = id || "default"; previewOptions = options; previewKind = kind; }
            function stopPreview() { previewId = ""; }
        }
    }
    Component { id: dialogComponent; Port.ClockSoundOptions {} }
    Component { id: spyComponent; SignalSpy { signalName: "applied" } }
    function test_options_preview_and_save_data() { return [{tag: "dark", dark: true}, {tag: "light", dark: false}]; }
    function test_options_preview_and_save(data) {
        var client = createTemporaryObject(clientComponent, test);
        var dialog = createTemporaryObject(dialogComponent, test, {client: client, darkMode: data.dark});
        var spy = createTemporaryObject(spyComponent, test, {target: dialog});
        dialog.openFor({volume: 33, startMs: 2000, extra: "preserved"}, "builtin-chime-01", "alarm");
        tryCompare(dialog, "visible", true);
        compare(dialog.volume, 33); compare(dialog.startSeconds, 2);
        dialog.volume = 45; dialog.fadeSeconds = 5; dialog.startSeconds = 3; dialog.durationSeconds = 12; dialog.repeats = false;
        mouseClick(findChild(dialog, "clockSoundOptionsPreview"));
        compare(client.previewKind, "alarm"); compare(client.previewOptions.volume, 45);
        compare(client.previewOptions.fadeMs, 5000); compare(client.previewOptions.startMs, 3000);
        compare(client.previewOptions.durationMs, 12000); compare(client.previewOptions.repeat, false);
        mouseClick(findChild(dialog, "clockSoundOptionsSave"));
        compare(spy.count, 1); compare(spy.signalArguments[0][0].extra, "preserved");
        compare(client.previewId, "");
    }
}

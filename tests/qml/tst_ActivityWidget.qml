import QtQuick
import QtTest
import "../../MacShell" as Port
import "../../MacShell/ActivityWidgetData.js" as Data

TestCase {
    id: test
    name: "ActivityWidget"; when: windowShown
    width: 700; height: 1100; visible: true
    Component { id: cardComponent; Port.ActivityWidget { style: "normal" } }
    Component { id: editorComponent; Port.WidgetAppearanceEditor { width: 520; controller: backend } }
    QtObject {
        id: backend
        property bool settingsEditable: true
        property var call: []
        signal mutationFinished(bool success)
        function commitWidgetAppearance(id, draft, baseline, type) { call = [id, draft, baseline, type]; return true; }
    }
    SignalSpy { id: openSpy; signalName: "openRequested" }
    function init() { backend.call = []; openSpy.clear(); openSpy.target = null; }
    function test_waiting_missing_and_zero_are_distinct() {
        var card = createTemporaryObject(cardComponent, test); waitForRendering(card);
        compare(card.status, "Waiting for data…");
        compare(findChild(card, "activityValue_cpu").text, "—");
        card.sample = {time: 10, gap: true, cpu: null, memory: {used: 0, total: 16 * 1073741824}, interface: "eth0", network: null}; card.stale = false;
        compare(card.status, "Measuring…");
        compare(findChild(card, "activityValue_cpu").text, "—");
        compare(findChild(card, "activityValue_memory").text, "0.0%");
        compare(findChild(card, "activitySecondary_network").text, "Measuring…");
        compare(findChild(card, "activitySecondary_disk").text, "Select a disk");
        card.sample = {time: 11, gap: false, cpu: 0, interface: "eth0", network: [0, 0], device: "disk0", disk: [0, 0]};
        compare(card.status, "Last 60 seconds"); compare(findChild(card, "activityValue_cpu").text, "0.0%");
        compare(findChild(card, "activityValue_network").text, "↓ 0 B/s");
        compare(findChild(card, "activitySecondary_disk").text, "W 0 B/s");
        card.stale = true; compare(card.status, "Waiting for fresh data…");
        compare(findChild(card, "activityValue_network").text, "—");
    }
    function test_shared_units_thresholds_and_precise_values() {
        var card = createTemporaryObject(cardComponent, test, {sample: {cpu: 72.5, time: 10, interface: "eth0", network: [1048576, 0]}, stale: false});
        compare(findChild(card, "activityValue_cpu").text, "72.5%");
        compare(findChild(card, "activityValue_network").text, "↓ 1.0 MB/s");
        card.appearance = {speedUnit: "binary", cpuWarning: 70, cpuCritical: 80};
        compare(findChild(card, "activityValue_network").text, "↓ 1.0 MiB/s");
        compare(Data.color("cpu", card.sample, false, card.appearance, true), "#f2c46d");
        card.appearance = {cpuWarning: 40, cpuCritical: 70};
        compare(Data.color("cpu", card.sample, false, card.appearance, true), "#ff786f");
        compare(Data.rate(null, true), "—"); compare(Data.rate(0, true), "0 B/s");
    }
    function test_metrics_and_graphs_are_local_and_io_is_not_a_percentage() {
        var card = createTemporaryObject(cardComponent, test, {size: "large", sample: Data.demoSample(1060, 60), history: Data.demoHistory(), stale: false});
        waitForRendering(card); compare(findChild(card, "activityTile_cpu").ring, true);
        compare(findChild(card, "activityTile_network").ring, false);
        compare(findChild(card, "activityGraph_network").visible, true);
        card.settings = {metrics: ["disk", "cpu"], view: "graphs"}; waitForRendering(card);
        compare(card.shownMetrics.join(), "disk,cpu"); compare(findChild(card, "activityTile_cpu").ring, false);
        compare(findChild(card, "activityGraph_cpu").visible, true);
        compare(findChild(card, "activityTile_memory"), null);
        compare(card.history.length, 61);
    }
    function test_only_live_interactive_views_open_details() {
        var card = createTemporaryObject(cardComponent, test); openSpy.target = card; waitForRendering(card);
        mouseClick(card); compare(openSpy.count, 0);
        card.interactive = true; mouseClick(card); compare(openSpy.count, 1);
        card.preview = true; mouseClick(card); compare(openSpy.count, 1);
        card.preview = false; card.editing = true; mouseClick(card); compare(openSpy.count, 1);
        card.editing = false; card.forceActiveFocus(); keyClick(Qt.Key_Return); compare(openSpy.count, 2);
        card.preview = true; keyClick(Qt.Key_Space); compare(openSpy.count, 2);
    }
    function test_metric_draft_preview_cancel_and_apply_keep_extensions() {
        var record = {id: "activity-one", type: "activity", supported: true, size: "small", style: "normal", defaultStyle: "liquid", mode: "auto",
            savedSettings: {style: "normal", activity: {metrics: ["cpu", "memory"], future: {keep: false}}, extra: 0}};
        var editor = createTemporaryObject(editorComponent, test, {record: record}); waitForRendering(editor);
        var preview = findChild(editor, "widgetAppearancePreview");
        compare(preview.visual.shownMetrics.join(), "cpu,memory");
        mouseClick(findChild(editor, "widgetActivityMetric_cpu"));
        compare(editor.activityMetrics.join(), "memory"); compare(findChild(editor, "widgetActivityMetric_memory").enabled, false);
        compare(preview.visual.shownMetrics.join(), "memory"); compare(backend.call.length, 0);
        mouseClick(findChild(editor, "widgetAppearanceCancel"));
        compare(editor.activityMetrics.join(), "cpu,memory"); compare(backend.call.length, 0);
        editor.changeActivity("view", "graphs"); editor.toggleMetric("disk"); editor.change("textScale", 1.2);
        editor.apply(); compare(backend.call[0], "activity-one"); compare(backend.call[3], "activity");
        compare(backend.call[1].activity.view, "graphs"); compare(backend.call[1].activity.metrics.join(), "cpu,memory,disk");
        compare(backend.call[1].activity.future.keep, false); compare(backend.call[1].extra, 0);
        compare(record.savedSettings.activity.metrics.join(), "cpu,memory");
    }
    function test_invalid_selections_are_rejected() {
        for (var settings of [null, [], {metrics: []}, {metrics: ["cpu", "cpu"]}, {metrics: ["gpu"]}, {metrics: "cpu"}, {view: "unknown"}])
            compare(Data.validSettings(settings), false);
        compare(Data.validSettings({metrics: ["network"], future: 0}), true);
    }
}

import QtQuick
import QtTest
import "../../MacShell" as Port

TestCase {
    id: test
    name: "ActivityBar"
    when: windowShown
    width: 800; height: 400; visible: true
    QtObject {
        id: readings
        property var sample: ({})
        property bool stale: false
        function gib(value) { return (value / 1073741824).toFixed(1); }
        function rate(value) { return value + "B"; }
    }
    Component { id: barComponent; Port.SystemStatsBar { controller: readings; foreground: "white"; y: 30 } }
    SignalSpy { id: clickedSpy; signalName: "clicked" }
    function init() {
        readings.sample = {cpu: 24, memory: {used: 8589934592, total: 17179869184}, network: [1000, 2000], disk: [3000, 4000]};
        readings.stale = false;
        clickedSpy.target = null; clickedSpy.clear();
    }
    function test_budget_and_independent_metrics() {
        var item = createTemporaryObject(barComponent, test);
        verify(item !== null);
        for (var selected of [["cpu", "memory", "network", "disk"], ["memory"], ["network", "disk"], []]) {
            item.metrics = selected;
            compare(item.shownMetrics.length, selected.length);
            for (var budget of [0, 10, 25, 26, 30, 48, 60, 91, 92, 119, 120, 250]) {
                item.budget = budget;
                verify(item.width <= budget, "Widget exceeds available space");
                compare(item.visible, selected.length > 0 && budget >= 26);
                compare(item.height, 28);
                for (var scale of [1, 1.25, 1.5]) {
                    item.scale = scale;
                    verify(item.width * scale <= budget * scale);
                }
            }
        }
        item.metrics = ["disk", "memory", "memory", "unknown"];
        compare(item.shownMetrics.join(","), "memory,disk");
        item.budget = 250;
        waitForRendering(item);
        verify(findChild(item, "activity_memory") !== null);
        compare(findChild(item, "activity_cpu"), null);
        item.metrics = ["cpu", "memory", "network", "disk"];
        item.budget = 120; compare(item.mode, 2); compare(item.width, 120);
        item.budget = 92; compare(item.mode, 1); compare(item.width, 92);
        item.budget = 26; compare(item.mode, 0);
        compare(findChild(item, "activitySummary").visible, true);
    }
    function test_pressure_colors_in_both_themes_data() {
        return [
            {tag: "dark-calm", foreground: "white", percent: 24, color: "#5dd9a3"},
            {tag: "dark-busy", foreground: "white", percent: 65, color: "#f2c46d"},
            {tag: "dark-high", foreground: "white", percent: 90, color: "#ff786f"},
            {tag: "light-calm", foreground: "#1d1d1f", percent: 24, color: "#157a55"},
            {tag: "light-busy", foreground: "#1d1d1f", percent: 65, color: "#a56c13"},
            {tag: "light-high", foreground: "#1d1d1f", percent: 90, color: "#c23532"}
        ];
    }
    function test_pressure_colors_in_both_themes(data) {
        var item = createTemporaryObject(barComponent, test, {foreground: data.foreground});
        readings.sample = {cpu: data.percent, memory: {used: data.percent, total: 100}};
        compare(item.level("cpu"), data.percent / 100);
        compare(item.level("memory"), data.percent / 100);
        compare(String(Qt.color(item.metricColor("cpu"))), data.color);
        compare(String(Qt.color(item.metricColor("memory"))), data.color);
    }
    function test_unknown_stale_and_idle_are_distinct() {
        var item = createTemporaryObject(barComponent, test);
        readings.sample = {cpu: 0, memory: {used: 0, total: 100}, network: [0, 0], disk: [0, 0]};
        for (var key of item.shownMetrics) compare(item.level(key), 0);
        compare(item.value("cpu"), "0%");
        compare(item.value("down"), "0B/s");
        var idleColor = item.metricColor("cpu");
        readings.stale = true;
        for (var key of item.shownMetrics) compare(item.level(key), -1);
        compare(item.value("cpu"), "—");
        verify(item.detail("cpu").indexOf("Waiting for fresh data") >= 0);
        verify(String(item.metricColor("cpu")) !== String(idleColor));
        readings.stale = false;
        readings.sample = {cpu: null, memory: {used: 50, total: 0}, network: null, disk: [null, 0]};
        for (var key of item.shownMetrics) {
            compare(item.level(key), -1);
            verify(item.detail(key).indexOf("Unavailable") >= 0);
        }
        readings.sample = {cpu: NaN, memory: {used: Infinity, total: 100}, network: [-1, 0], disk: [Infinity, 0]};
        for (var key of item.shownMetrics) compare(item.level(key), -1);
    }
    function test_io_activity_is_bounded_and_never_pressure_red() {
        var item = createTemporaryObject(barComponent, test);
        var previous = -1;
        for (var rate of [0, 1000, 1000000, 100000000, 10000000000]) {
            readings.sample = {network: [rate, rate], disk: [rate, rate]};
            verify(item.level("network") >= previous);
            verify(item.level("network") <= 1);
            verify(item.level("disk") >= 0 && item.level("disk") <= 1);
            verify(String(item.metricColor("network")) !== "#ff786f");
            verify(String(item.metricColor("disk")) !== "#ff786f");
            previous = item.level("network");
        }
        readings.sample = {cpu: 99, memory: {used: 50, total: 100}, network: [1e9, 1e9]};
        compare(item.summaryMetric, "cpu");
        item.metrics = ["memory", "network"];
        compare(item.summaryMetric, "memory");
        item.metrics = ["network"];
        compare(item.summaryMetric, "network");
    }
    function test_custom_thresholds_monochrome_units_and_metric_order() {
        var item = createTemporaryObject(barComponent, test, {appearance: {cpuWarning: 20, cpuCritical: 90, memoryWarning: 85, memoryCritical: 95, order: ["disk", "memory", "network", "cpu"], speedUnit: "binary"}});
        compare(item.shownMetrics.join(","), "disk,memory,network,cpu");
        compare(item.severity("cpu"), 1);
        compare(item.severity("memory"), 0);
        compare(item.summaryMetric, "cpu");
        compare(String(Qt.color(item.metricColor("cpu"))), "#f2c46d");
        readings.sample = {cpu: 24, memory: {used: 80, total: 100}, network: [1048576, 0], disk: [0, 0]};
        compare(item.summaryMetric, "cpu");
        compare(item.value("down"), "1.0 MiB/s");
        compare(item.value("up"), "0 B/s");
        item.appearance = {palette: "monochrome"};
        var color = Qt.color(item.metricColor("cpu"));
        compare(color.r, color.g); compare(color.g, color.b);
        item.metrics = ["memory"];
        compare(item.shownMetrics.join(","), "memory");
    }
    function test_tooltip_values_and_click_keyboard_activation() {
        var item = createTemporaryObject(barComponent, test);
        clickedSpy.target = item;
        waitForRendering(item);
        var tip = findChild(item, "activityTooltip");
        mouseMove(item, 18, 14);
        tryCompare(tip, "opened", true, 2000);
        compare(tip.text, "CPU · 24%");
        mouseMove(item, 46, 14);
        tryCompare(item, "hoveredMetric", "memory");
        compare(tip.text, "Memory · 8.0 GiB / 16.0 GiB");
        item.memoryPercent = true;
        compare(tip.text, "Memory · 50%");
        mouseClick(item, 46, 14);
        compare(clickedSpy.count, 1);
        item.forceActiveFocus();
        keyClick(Qt.Key_Return); keyClick(Qt.Key_Space);
        compare(clickedSpy.count, 3);
        item.budget = 26;
        mouseMove(item, 13, 14);
        compare(tip.text, item.summary);
        verify(tip.text.indexOf("Network · ↓ 1000B/s  ↑ 2000B/s") >= 0);
        item.tooltipsEnabled = false;
        tryCompare(tip, "visible", false);
        mouseMove(test, 600, 300);
    }
}

import QtQuick
import QtTest
import "../../MacShell" as Port
import "../../MacShell/StatsHistory.js" as History

TestCase {
    id: test; name: "StatsGraph"; when: windowShown
    width: 320; height: 60; visible: true
    Rectangle { anchors.fill: parent; color: "#101010" }
    Component { id: graphComponent; Port.StatsGraph { width: 300; height: 40 } }
    function test_write_only_history_affects_scale_and_remains_visible() {
        var history = [{time: 0, gap: false, disk: [0, 50]}, {time: 30, gap: false, disk: [0, 100]}, {time: 60, gap: false, disk: [0, 200]}];
        var graph = createTemporaryObject(graphComponent, test, {history: history, metric: "disk", primaryColor: "cyan", secondaryColor: "#ff40e0"});
        compare(graph.lines.length, 2); compare(graph.lines[0].join(), "0,0,0"); compare(graph.lines[1].join(), "50,100,200"); compare(graph.ceiling, 200);
        function magentaPixels() {
            var image = grabImage(test), count = 0;
            for (var y = 0; y < 40; y++) for (var x = 0; x < 300; x++) {
                var p = image.pixel(x, y);
                if (p.r > .7 && p.b > .6 && p.g < .5) count++;
            }
            return count;
        }
        tryVerify(() => magentaPixels() > 20, 1000, "Writes must draw a separate visible curve");
    }
    function test_upload_and_missing_values_use_independent_series() {
        var data = [{network: null}, {network: [0, 99]}, {network: [undefined, -1]}, {network: [NaN, 50]}];
        var lines = History.series(data, "network");
        compare(lines[0][0], null); compare(lines[0][1], 0); compare(lines[0][2], null); compare(lines[0][3], null);
        compare(lines[1][1], 99); compare(lines[1][2], null); compare(lines[1][3], 50);
        compare(History.ceiling(lines, "network"), 99);
    }
    function test_percentages_keep_fixed_scale_and_invalid_memory_is_unknown() {
        var data = [{cpu: 0, memory: {used: 0, total: 100}}, {cpu: 40, memory: {used: 25, total: 100}}, {cpu: null, memory: {used: 5, total: 0}}];
        compare(History.series(data, "cpu")[0][0], 0); compare(History.series(data, "cpu")[0][2], null);
        compare(History.series(data, "memory")[0][1], 25); compare(History.series(data, "memory")[0][2], null);
        compare(History.ceiling(History.series(data, "cpu"), "cpu"), 100);
        compare(History.ceiling([], "disk"), 1);
    }
}

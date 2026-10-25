import QtQuick
import "StatsHistory.js" as History

Canvas {
    id: root
    property var history: []
    property string metric: "cpu"
    property color primaryColor: "#0a84ff"
    property color secondaryColor: "#a887f3"
    readonly property var lines: History.series(history, metric)
    readonly property real ceiling: History.ceiling(lines, metric)
    implicitHeight: 34
    onHistoryChanged: requestPaint()
    onMetricChanged: requestPaint()
    onPrimaryColorChanged: requestPaint()
    onSecondaryColorChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onAvailableChanged: if (available) requestPaint()
    onPaint: {
        var c = getContext("2d"), end = history.length ? history[history.length - 1].time : 0;
        c.reset(); c.clearRect(0, 0, width, height); c.lineWidth = 1.5;
        lines.forEach((values, index) => {
            c.strokeStyle = index === 0 ? primaryColor : secondaryColor;
            c.fillStyle = c.strokeStyle; c.beginPath(); var started = false, points = 0, lastX = 0, lastY = 0;
            function dot() { if (points === 1) { c.moveTo(lastX + 1, lastY); c.arc(lastX, lastY, 1, 0, 2 * Math.PI); } }
            for (var i = 0; i < history.length; i++) {
                if (history[i].gap || values[i] === null) { dot(); started = false; points = 0; continue; }
                var x = width * (1 - (end - history[i].time) / 60), y = height - 2 - values[i] / ceiling * (height - 4);
                if (started) c.lineTo(x, y); else c.moveTo(x, y);
                started = true; points++; lastX = x; lastY = y;
            }
            dot(); c.stroke();
        });
    }
}

import QtQuick

Item {
    id: root
    property string precision: "off"
    property var smoothNow: new Date()
    property var secondNow: new Date()
    property var minuteNow: new Date()
    property var dayNow: new Date()
    property double lastSecond: -1
    property string minuteKey: ""
    property string dayKey: ""
    readonly property bool running: tick.running
    readonly property int interval: precision === "smooth" ? 33 : precision === "date" ? 30000 : 1000
    function update(date) {
        if (precision === "smooth") smoothNow = date;
        var second = Math.floor(date.getTime() / 1000);
        if (second === lastSecond) return;
        lastSecond = second; secondNow = date;
        var day = date.toDateString(), minute = day + " " + date.getHours() + ":" + date.getMinutes() + " " + date.getTimezoneOffset();
        if (minute !== minuteKey) { minuteKey = minute; minuteNow = date; }
        if (day !== dayKey) { dayKey = day; dayNow = date; }
    }
    function timeFor(mode) { return mode === "hidden" ? minuteNow : mode === "tick" ? secondNow : smoothNow; }
    onPrecisionChanged: if (precision !== "off") update(new Date())
    Timer {
        id: tick; objectName: "widgetClockTick"
        interval: root.interval; repeat: true; running: root.precision !== "off"
        onTriggered: root.update(new Date())
    }
}

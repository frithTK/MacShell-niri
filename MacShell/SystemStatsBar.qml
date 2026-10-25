import QtQuick
import QtQuick.Controls as Controls

Item {
    id: root
    required property var controller
    required property color foreground
    property color accent: "#0a84ff"
    property string fontFamily: ""
    property real budget: 250
    property var metrics: ["cpu", "memory", "network", "disk"]
    property bool memoryPercent: false
    property var appearance: ({})
    property bool active: false
    property bool tooltipsEnabled: true
    readonly property bool dark: foreground.r + foreground.g + foreground.b > 1.5
    readonly property var shownMetrics: (appearance.order || ["cpu", "memory", "network", "disk"]).filter(key => metrics.indexOf(key) >= 0)
    readonly property int fullWidth: shownMetrics.length * 28 + 8
    readonly property int compactWidth: shownMetrics.length * 22 + 4
    readonly property int mode: budget >= fullWidth ? 2 : budget >= compactWidth ? 1 : budget >= 26 ? 0 : -1
    readonly property real cellWidth: mode === 2 ? 28 : 22
    readonly property real inset: mode === 2 ? 4 : 2
    readonly property string hoveredMetric: mode > 0 && pointer.containsMouse
        ? shownMetrics[Math.max(0, Math.min(shownMetrics.length - 1, Math.floor((pointer.mouseX - inset) / cellWidth)))] || "" : ""
    readonly property string summary: shownMetrics.map(key => detail(key)).join("\n")
    readonly property string summaryMetric: {
        // In the single-icon view, CPU/RAM pressure takes priority over I/O activity.
        var known = shownMetrics.filter(key => level(key) >= 0);
        var pressure = known.filter(key => key === "cpu" || key === "memory");
        return (pressure.length ? pressure : known).reduce((a, b) => severity(b) > severity(a)
            || severity(b) === severity(a) && level(b) > level(a) ? b : a, "");
    }
    width: shownMetrics.length === 0 || mode < 0 ? 0 : mode === 0 ? 26 : mode === 2 ? fullWidth : compactWidth
    height: 28
    visible: width > 0
    activeFocusOnTab: visible
    Accessible.role: Accessible.Button
    Accessible.name: "Activity Monitor"
    Accessible.description: summary
    Accessible.onPressAction: root.clicked()
    Keys.onReturnPressed: root.clicked()
    Keys.onEnterPressed: root.clicked()
    Keys.onSpacePressed: root.clicked()
    signal clicked()

    function valid(value) { return typeof value === "number" && isFinite(value) && value >= 0; }
    function level(key) {
        if (controller.stale) return -1;
        var s = controller.sample;
        if (key === "cpu") return valid(s.cpu) ? Math.min(1, s.cpu / 100) : -1;
        if (key === "memory") return s.memory && valid(s.memory.used) && valid(s.memory.total) && s.memory.total > 0
            ? Math.min(1, s.memory.used / s.memory.total) : -1;
        var rates = key === "network" ? s.network : key === "disk" ? s.disk : null;
        if (!rates || !valid(rates[0]) || !valid(rates[1])) return -1;
        // Logarithmic activity scale, not a percentage of device/link capacity.
        var reference = key === "network" ? 100000000 : 1000000000;
        return Math.min(1, Math.log(1 + (rates[0] + rates[1]) / 1024) / Math.log(1 + reference / 1024));
    }
    function metricColor(key) {
        var amount = level(key);
        if (amount < 0) return Qt.rgba(foreground.r, foreground.g, foreground.b, .35);
        if (appearance.palette === "monochrome") return Qt.rgba(foreground.r, foreground.g, foreground.b, .65 + amount * .35);
        if (key === "cpu" || key === "memory") {
            if (severity(key) === 2) return dark ? "#ff786f" : "#c23532";
            if (severity(key) === 1) return dark ? "#f2c46d" : "#a56c13";
            return dark ? "#5dd9a3" : "#157a55";
        }
        var tint = Qt.color(key === "network" ? (dark ? "#73bfff" : "#286ab0") : (dark ? "#b5a0f4" : "#7854b3"));
        return Qt.rgba(tint.r, tint.g, tint.b, .45 + amount * .55);
    }
    function severity(key) {
        var amount = level(key);
        if (amount < 0) return -1;
        if (key !== "cpu" && key !== "memory") return 0;
        var prefix = key === "cpu" ? "cpu" : "memory";
        var critical = appearance[prefix + "Critical"] === undefined ? 90 : appearance[prefix + "Critical"];
        var warning = appearance[prefix + "Warning"] === undefined ? 65 : appearance[prefix + "Warning"];
        return amount * 100 >= critical ? 2 : amount * 100 >= warning ? 1 : 0;
    }
    function value(key) {
        var s = controller.sample;
        if (controller.stale) return "—";
        if (key === "cpu") return level(key) < 0 ? "—" : Math.round(level(key) * 100) + "%";
        if (key === "memory") return level(key) < 0 ? "—" : memoryPercent
            ? Math.round(level(key) * 100) + "%" : controller.gib(s.memory.used) + " GiB";
        var rates = key === "down" || key === "up" ? s.network : s.disk;
        var v = rates && rates[key === "down" || key === "read" ? 0 : 1];
        if (!valid(v)) return "—";
        if (appearance.speedUnit !== "binary") return controller.rate(v) + "/s";
        var units = ["B", "KiB", "MiB", "GiB"], i = 0;
        while (v >= 1024 && i < 3) { v /= 1024; i++; }
        return (v >= 100 || i === 0 ? v.toFixed(0) : v.toFixed(1)) + " " + units[i] + "/s";
    }
    function detail(key) {
        var title = ({cpu: "CPU", memory: "Memory", network: "Network", disk: "Disk"})[key];
        if (controller.stale) return title + " · Waiting for fresh data…";
        if (level(key) < 0) return title + " · Unavailable";
        if (key === "cpu") return title + " · " + value(key);
        if (key === "memory") return title + " · " + value(key) + (memoryPercent ? "" : " / " + controller.gib(controller.sample.memory.total) + " GiB");
        return key === "network" ? title + " · ↓ " + value("down") + "  ↑ " + value("up")
            : title + " · Read " + value("read") + "  Write " + value("write");
    }

    Rectangle {
        x: 1; y: 2; width: root.width - 2; height: 24; radius: 6
        color: root.active || pointer.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, root.dark ? .12 : .08) : "transparent"
        border.width: root.activeFocus ? 1 : 0
        border.color: root.accent
    }
    Row {
        x: root.inset; height: 28
        visible: root.mode > 0
        Repeater {
            model: root.shownMetrics
            delegate: Item {
                required property string modelData
                objectName: "activity_" + modelData
                width: root.cellWidth; height: 28
                ShellGlyph {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: 3; width: 18; height: 18
                    kind: modelData
                    color: root.metricColor(modelData)
                }
                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: 23; width: 14; height: 2; radius: 1
                    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, root.dark ? .18 : .14)
                    Rectangle {
                        width: parent.width * Math.max(0, root.level(modelData)); height: parent.height; radius: 1
                        color: root.metricColor(modelData)
                    }
                }
            }
        }
    }
    ShellGlyph {
        objectName: "activitySummary"
        visible: root.mode === 0
        anchors.centerIn: parent
        kind: "activity"
        color: root.metricColor(root.summaryMetric)
    }
    MouseArea {
        id: pointer
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }
    Controls.ToolTip {
        id: tip
        objectName: "activityTooltip"
        visible: root.tooltipsEnabled && pointer.containsMouse && root.visible
        delay: 600
        x: Math.round((root.width - width) / 2); y: root.height + 6
        text: root.hoveredMetric ? root.detail(root.hoveredMetric) : root.summary
        background: Rectangle {
            radius: 8
            color: root.dark ? "#303035" : "#fafafb"
            border.color: root.dark ? "#55555b" : "#d5d5da"
        }
        contentItem: Text { text: tip.text; color: root.foreground; font.family: root.fontFamily; font.pixelSize: 12 }
    }
}

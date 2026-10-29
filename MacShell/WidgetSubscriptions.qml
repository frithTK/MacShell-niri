import QtQuick
import "WidgetCatalog.js" as Catalog

QtObject {
    id: root
    property var instances: []
    property bool enabled: true
    property var views: []
    property int acquired: 0
    property int released: 0
    readonly property var activeViews: enabled ? views.filter(view => view && view.active && instances.some(row =>
        row.wid === view.instanceId && row.wtype === view.widgetType && row.woutput === view.outputName)) : []
    readonly property var consumers: {
        var result = [];
        activeViews.forEach(view => {
            var item = result.find(item => item.id === view.instanceId);
            if (!item) { item = {id: view.instanceId, type: view.widgetType, output: view.outputName, lyrics: false}; result.push(item); }
            if (view.lyricsOpen) item.lyrics = true;
        });
        return result;
    }
    readonly property var counts: {
        var result = {weather: 0, player: 0, lyrics: 0, time: 0, date: 0, stats: 0, batteries: 0};
        consumers.forEach(item => {
            var definition = Catalog.find(item.type);
            if (definition) definition.data.forEach(source => {
                if (source !== "lyrics" || item.lyrics) result[source] = (result[source] || 0) + 1;
            });
        });
        return result;
    }
    readonly property string clockPrecision: {
        var clocks = activeViews.filter(view => view.widgetType === "clock");
        if (clocks.some(view => view.secondsMode === "smooth")) return "smooth";
        if (clocks.some(view => view.secondsMode === "tick")) return "tick";
        return clocks.length ? "minute" : counts.date ? "date" : "off";
    }
    function acquire(view) {
        // A parent delegate can invalidate its child QObjects before their
        // destruction handlers run; remove those weak entries as well.
        release(null);
        if (views.indexOf(view) >= 0) return;
        views = views.concat([view]); acquired++;
    }
    function release(view) {
        var next = views.filter(item => item && typeof item.instanceId === "string" && item !== view);
        var removed = views.length - next.length;
        if (!removed) return;
        views = next; released += removed;
    }
}

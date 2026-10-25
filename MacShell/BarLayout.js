.pragma library

function clone(value) { return JSON.parse(JSON.stringify(value)); }
function defaults(catalog) {
    return catalog.filter(block => !block.repeatable).map(block => ({id: block.type, type: block.type, zone: block.zone, enabled: true, priority: block.priority}));
}
function label(catalog, type) { var block = catalog.find(item => item.type === type); return block ? block.label : type + " (unavailable)"; }
function solve(layout, catalog, measurements, width) {
    width = Math.max(0, Number(width) || 0);
    var byCatalog = Object.create(null), items = Object.create(null), byType = Object.create(null), hidden = [], overflow = [], groups = {left: [], center: [], right: []};
    catalog.forEach(block => byCatalog[block.type] = block);
    layout.forEach((record, index) => {
        var definition = byCatalog[record.type], measurement = measurements[record.type] || {};
        if (!definition || !record.enabled || measurement.available === false) return;
        var preferred = record.type === "spacer" ? (record.width === undefined ? 16 : record.width) : (measurement.preferred === undefined ? definition.width : measurement.preferred);
        var forms = measurement.forms || (definition.compact ? [preferred, Math.min(preferred, definition.compact)] : [preferred]);
        if (record.type === "spacer") forms = [preferred, 0];
        forms = forms.map(value => Math.max(0, Number(value) || 0));
        var entry = {id: record.id, type: record.type, zone: record.zone, priority: record.priority, index: index, forms: forms, mode: 0, width: forms[0], x: 0};
        groups[record.zone].push(entry); items[record.id] = entry;
    });
    var entries = Object.keys(items).map(key => items[key]);
    function extent(zone) { return groups[zone].reduce((total, item) => total + item.width, 0); }
    function cost(extra) {
        var zones = ["left", "center", "right"].filter(zone => extent(zone) > 0).length;
        return 14 + extent("left") + extent("center") + extent("right") + Math.max(0, zones - 1) * 12 + extra;
    }
    var order = entries.slice().sort((a, b) => a.priority - b.priority || a.index - b.index);
    order.forEach(entry => {
        while (cost(0) > width && entry.mode + 1 < entry.forms.length) {
            entry.mode++; entry.width = Math.min(entry.width, entry.forms[entry.mode]);
        }
    });
    if (cost(0) > width) {
        for (var i = 0; i < order.length && cost(overflow.length ? 30 : 0) > width; i++) {
            var entry = order[i];
            if (entry.width <= 0) continue;
            entry.width = 0; hidden.push(entry.id);
            if (entry.type !== "spacer") overflow.push(entry);
        }
    }
    // Overflow is always reachable, including widths too small for any block.
    var overflowWidth = overflow.length ? Math.min(26, width) : 0;
    var rightEdge = Math.max(0, width - (overflow.length ? overflowWidth + 10 : 6));
    var left = 8, right = rightEdge - extent("right");
    var centerWidth = extent("center"), leftWidth = extent("left");
    var center = Math.max(left + leftWidth + (leftWidth && centerWidth ? 12 : 0), Math.min((width - centerWidth) / 2, right - (centerWidth && extent("right") ? 12 : 0) - centerWidth));
    var starts = {left: left, center: center, right: right};
    ["left", "center", "right"].forEach(zone => groups[zone].forEach(entry => {
        entry.x = starts[zone]; starts[zone] += entry.width; byType[entry.type] = entry;
    }));
    overflow.sort((a, b) => a.index - b.index);
    return {items: items, byType: byType, overflow: overflow, overflowX: Math.max(0, width - overflowWidth - 6), overflowWidth: overflowWidth};
}
function popupX(anchor, width, scale, origin, screenWidth, leading) {
    var physical = width * scale;
    var left = Math.max(6, Math.min(Math.max(6, screenWidth - physical - 6), leading ? anchor : anchor - physical / 2));
    return left - width * (1 - scale) * origin;
}

.pragma library

function formatDeleted(value) {
    var text = String(value || "");
    var match = text.match(/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/);
    if (!match)
        return text;
    return match[3] + "." + match[2] + "." + match[1] + " " + match[4] + ":" + match[5];
}

function matchesQuery(item, query) {
    var q = String(query || "").trim().toLowerCase();
    if (!q)
        return true;
    if (!item)
        return false;
    return String(item.name || "").toLowerCase().indexOf(q) >= 0
        || String(item.originalPath || "").toLowerCase().indexOf(q) >= 0;
}

function visibleItems(items, query) {
    var all = items || [];
    var out = [];
    for (var i = 0; i < all.length; i++) {
        if (matchesQuery(all[i], query))
            out.push(all[i]);
    }
    return out;
}
